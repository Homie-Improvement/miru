# frozen_string_literal: true

require "csv"
require "bigdecimal"
require "digest/sha2"

module Imports
  class HarvestTimeEntriesImporter
    class InvalidFileError < StandardError; end

    # Raised when the user who started the import no longer works in the
    # company. A forwarded write is refused by the token check; this stops a
    # legacy write, which mints no token, the same way.
    class ImportUserNotInCompany < StandardError; end

    REQUIRED_HEADERS = %w[date client project hours first\ name last\ name].freeze
    HEADER_CONVERTER = -> (header) { header.to_s.delete_prefix("\uFEFF").strip.downcase }
    DATE_FORMATS = {
      "DD-MM-YYYY" => "%d-%m-%Y",
      "MM-DD-YYYY" => "%m-%d-%Y",
      "YYYY-MM-DD" => "%Y-%m-%d"
    }.freeze

    # The values a row's Idempotency-Key is derived from: the row as read from
    # the uploaded file, line number included, so two identical lines stay two
    # entries. Values resolved from the workspace (user, project, bill status,
    # and the currency, which falls back to the company's base currency) are
    # left out because they can change before a rerun, which would give a row
    # already written a new key.
    ROW_KEY_FIELDS = %i[
      row date client_name project_name project_code user_name hours billable invoiced note hourly_rate
    ].freeze

    attr_reader :data_import, :company

    def initialize(data_import)
      @data_import = data_import
      @company = data_import.company
    end

    def self.validate_headers!(path)
      CSV.open(path, "r:bom|utf-8", headers: true, liberal_parsing: true, header_converters: HEADER_CONVERTER) do |csv|
        csv.shift
        missing = REQUIRED_HEADERS - Array(csv.headers)
        if missing.any?
          raise InvalidFileError, I18n.t("imports.errors.missing_headers", headers: missing.map(&:titleize).join(", "))
        end
      end
    rescue CSV::MalformedCSVError => error
      raise InvalidFileError, I18n.t("imports.errors.invalid_csv", message: error.message)
    end

    def process
      previous_context = Rails.event.context.dup
      Rails.event.set_context(source: "harvest_import", data_import_id: data_import.id.to_s)
      data_import.update!(
        status: "processing",
        started_at: Time.current,
        finished_at: nil,
        error_message: nil,
        total_rows: 0,
        imported_rows: 0,
        failed_rows: 0,
        skipped_rows: 0,
        summary: {},
        row_errors: []
      )

      load_rows
      load_workspace_records
      build_plan
      persist_plan
      persist_entries unless data_import.dry_run?
      complete_import
      data_import
    rescue StandardError => error
      fail_import(error)
      raise
    ensure
      Rails.event.clear_context
      Rails.event.set_context(previous_context)
    end

    private

      def fail_import(error)
        message = error.message
        unless error.is_a?(InvalidFileError)
          Rails.logger.error("Data import ##{data_import.id} failed: #{message}")
          message = I18n.t("imports.errors.unexpected")
        end
        # Each entry commits on its own, so the rows written before the failure
        # stay stored and are reported, with the row errors met so far.
        data_import.update!(status: "failed", error_message: message, finished_at: Time.current,
                            imported_rows: @imported_rows.to_i, failed_rows: @failed_rows.to_i,
                            row_errors: @row_errors.to_a)
      end

      def load_rows
        @rows = []

        data_import.file.open do |file|
          self.class.validate_headers!(file.path)
          CSV.open(file.path, "r:bom|utf-8", headers: true, liberal_parsing: true, header_converters: HEADER_CONVERTER) do |csv|
            csv.each { |row| @rows << normalized_row(row, csv.lineno) }
          end
        end
      rescue CSV::MalformedCSVError => error
        raise InvalidFileError, I18n.t("imports.errors.invalid_csv", message: error.message)
      end

      def normalized_row(row, line_number)
        values = row.to_h.transform_values { |value| value.to_s.strip }
        task = values["task"]
        notes = values["notes"]

        {
          row: line_number,
          date: values["date"],
          client_name: values["client"],
          project_name: values["project"],
          project_code: values["project code"],
          user_name: [values["first name"], values["last name"]].compact_blank.join(" "),
          hours: values["hours"],
          billable: yes?(values["billable?"]),
          invoiced: yes?(values["invoiced?"]),
          note: [task, notes].compact_blank.join(" - "),
          currency: values["currency"].to_s[/([A-Z]{3})\z/, 1] || company.base_currency,
          hourly_rate: BigDecimal(values["billable rate"], exception: false) || 0
        }
      end

      def yes?(value)
        value.to_s.casecmp?("yes")
      end

      def load_workspace_records
        @users = company.users.merge(Employment.kept).distinct.to_a
        @users_by_email = @users.index_by { |user| key(user.email) }
        @users_by_name = @users.group_by { |user| key(user.full_name) }
        @user_map = data_import.options.fetch("user_map", {}).to_h.transform_keys { |name| key(name) }
        @assigned_user = @users_by_email[key(data_import.options["assign_unmatched_to"])]
        @existing_clients = company.clients.to_a.index_by { |client| key(client.name) }
        @existing_projects = Project.joins(:client)
          .where(clients: { company_id: company.id })
          .includes(:client)
          .to_a
          .index_by { |project| [project.client_id, key(project.name)] }
        load_legacy_names
      end

      def build_plan
        initialize_plan

        build_entity_plans
        load_database_duplicates
        @project_plans.each_value do |plan|
          if plan[:existing] && !plan[:existing].billable && plan[:billable]
            @warnings << "Harvest marks #{project_label(plan)} billable, but the Miru project is non-billable"
          end
        end
        @rows.each { |row| plan_row(row) }
        skip_stored_duplicates
        @summary = build_summary
      end

      def initialize_plan
        @warnings = Set.new
        @row_errors = []
        @zero_hour_rows = 0
        @duplicate_rows = 0
        @client_plans = {}
        @project_plans = {}
        @planned_rows = []
        @failed_rows = 0
        @imported_rows = 0
      end

      def load_database_duplicates
        project_ids = @project_plans.values.filter_map { |plan| plan[:existing]&.id }.uniq
        work_dates = @rows.filter_map { |row| parse_date(row[:date]) }
        @stored_duplicates = if project_ids.empty? || work_dates.empty?
          {}
        else
          TimesheetEntry.kept.joins(project: :client)
            .merge(Project.kept)
            .merge(Client.kept)
            .where(project_id: project_ids, work_date: work_dates.min..work_dates.max, source: "import")
            .pluck(:user_id, :project_id, :work_date, :duration, :note)
            .map { |values| duplicate_key(*values) }
            .tally
        end
      end

      def build_entity_plans
        @rows.each do |row|
          next if row[:client_name].blank? || row[:project_name].blank?

          client_key, client_plan = build_client_plan(row)

          original_project_name = row[:project_name]
          project_name = import_name(original_project_name)
          existing_project = client_plan[:existing] && @existing_projects[[client_plan[:existing].id, key(project_name)]]
          if existing_project.nil? && (legacy_name = legacy_import_name(original_project_name, @legacy_project_names))
            existing_project = client_plan[:existing] && @existing_projects[[client_plan[:existing].id, key(legacy_name)]]
            project_name = legacy_name if existing_project
          end
          @warnings << "Project name truncated: #{original_project_name.truncate(80)}" if original_project_name.length > 30
          project_key = [client_key, key(project_name)]
          row[:project_plan] = @project_plans[project_key] ||= {
            name: project_name,
            source_name: original_project_name,
            client: client_plan,
            existing: existing_project,
            billable: false,
            code: nil
          }
          project_plan = row[:project_plan]
          @warnings << "Restored archived project: #{project_label(project_plan)}" if project_plan[:existing]&.discarded?
          project_plan[:billable] ||= row[:billable]
          project_plan[:code] ||= row[:project_code].presence
        end
      end

      def build_client_plan(row)
        original_name = row[:client_name]
        client_name = import_name(original_name)
        if !@existing_clients.key?(key(client_name)) && (legacy_name = legacy_import_name(original_name, @legacy_client_names))
          client_name = legacy_name if @existing_clients.key?(key(legacy_name))
        end
        @warnings << "Client name truncated: #{original_name.truncate(80)}" if original_name.length > 30
        client_key = key(client_name)
        client_plan = @client_plans[client_key] ||= {
          name: client_name,
          existing: @existing_clients[client_key],
          currency: row[:currency]
        }
        @warnings << "Restored archived client: #{client_name}" if client_plan[:existing]&.discarded?
        [client_key, client_plan]
      end

      def import_name(name)
        return name if name.length <= 30

        suffix = "-#{Digest::SHA256.hexdigest(key(name)).first(6)}"
        "#{name.first(30 - suffix.length)}#{suffix}"
      end

      def load_legacy_names
        warnings = company.data_imports.where(source: "harvest", kind: "time_entries", status: "completed", dry_run: false)
          .pluck(:summary)
          .flat_map { |summary| Array(summary["warnings"]) }
        @legacy_client_names = legacy_names(warnings, "Client")
        @legacy_project_names = legacy_names(warnings, "Project")
      end

      def legacy_names(warnings, entity)
        prefix = "#{entity} name truncated: "
        names = warnings.filter_map do |warning|
          warning.delete_prefix(prefix) if warning.start_with?(prefix) && !warning.end_with?("...")
        end
        names.group_by { |name| key(name.first(30)) }.transform_values do |matches|
          matches.first if matches.map { |name| key(name) }.uniq.one?
        end.compact
      end

      def legacy_import_name(name, legacy_names)
        legacy_name = legacy_names[key(name.first(30))]
        name.first(30) if legacy_name && key(legacy_name) == key(name)
      end

      def plan_row(row)
        error = row_error(row)
        return add_row_error(row, error) if error

        duration = duration_in_minutes(row[:hours])
        return add_row_error(row, "Hours is invalid") unless duration
        if duration <= 0
          @zero_hour_rows += 1
          return
        end

        work_date = parse_date(row[:date])
        return add_row_error(row, "Date is invalid: #{row[:date]}") unless work_date

        user_name = row[:user_name]
        user = resolved_user(user_name)
        unless user
          return add_row_error(row, unmatched_user_message(user_name))
        end

        project_plan = row[:project_plan]
        bill_status = bill_status(row, project_plan)

        project = project_plan[:existing]
        @planned_rows << row.merge(
          user:,
          project_plan:,
          work_date:,
          duration:,
          bill_status:,
          duplicate_key: project && duplicate_key(user.id, project.id, work_date, duration, row[:note])
        )
      end

      # A row an earlier run of this import already tried to write (its line is
      # in attempted_rows) accounts for one stored match, and is skipped when
      # that match is stored here. Every other row matching a stored entry is
      # skipped however often it repeats, so a stored entry of another import
      # still skips all of its matching rows, while an identical row a failed
      # run never wrote is written on the rerun.
      def skip_stored_duplicates
        attempted = data_import.attempted_rows.to_set
        unmatched = @stored_duplicates.dup
        own, others = @planned_rows.partition { |row| attempted.include?(row[:row]) }
        skipped = own.select { |row| take_stored_match(unmatched, row[:duplicate_key]) }
        skipped += others.select { |row| unmatched.fetch(row[:duplicate_key], 0).positive? }
        @duplicate_rows = skipped.size
        @planned_rows -= skipped
      end

      def take_stored_match(unmatched, key)
        return false unless unmatched.fetch(key, 0).positive?

        unmatched[key] -= 1
        true
      end

      def unmatched_user_message(user_name)
        if ambiguous_user?(user_name)
          "Harvest user \"#{user_name}\" matches more than one team member; pass --map \"#{user_name}=their@email\"."
        else
          "No team member in this Miru workspace matches Harvest user \"#{user_name}\". Invite them, or pass --map \"#{user_name}=their@email\"."
        end
      end

      def row_error(row)
        return "Client is blank" if row[:client_name].blank?
        return "Project is blank" if row[:project_name].blank?
        "First Name and Last Name are blank" if row[:user_name].blank?
      end

      def duration_in_minutes(hours)
        decimal = BigDecimal(hours, exception: false)
        (decimal * 60).round if decimal&.finite?
      end

      def parse_date(value)
        Date.iso8601(value)
      rescue Date::Error
        formats = [DATE_FORMATS[company.date_format], "%m/%d/%Y"].compact.uniq
        formats.each do |format|
          return Date.strptime(value, format)
        rescue Date::Error
          next
        end
        nil
      end

      def resolved_user(name)
        name_key = key(name)
        mapped_user = @users_by_email[key(@user_map[name_key])]
        return mapped_user if mapped_user

        matching_users = @users_by_name.fetch(name_key, [])
        return if matching_users.many?

        matching_users.first || @assigned_user
      end

      def ambiguous_user?(name)
        !@users_by_email.key?(key(@user_map[key(name)])) && @users_by_name.fetch(key(name), []).many?
      end

      def bill_status(row, project_plan)
        project_billable = project_plan[:existing]&.billable || (!project_plan[:existing] && project_plan[:billable])
        if row[:billable] && project_billable
          row[:invoiced] ? "billed" : "unbilled"
        else
          "non_billable"
        end
      end

      def add_row_error(row, message)
        @failed_rows += 1
        if @row_errors.length < DataImport::MAX_ROW_ERRORS
          @row_errors << { "row" => row[:row], "message" => message }
        end
      end

      def build_summary
        dates = @rows.filter_map { |row| parse_date(row[:date]) }
        users = build_user_summary
        existing_clients = @client_plans.values.filter_map { |plan| plan[:existing]&.name }.sort
        new_clients = @client_plans.values.reject { |plan| plan[:existing] }.pluck(:name).sort.first(200)
        existing_projects = @project_plans.values.filter_map do |plan|
          project_label(plan) if plan[:existing]
        end.sort
        new_projects = @project_plans.values.reject do |plan|
          plan[:existing]
        end.map { |plan| project_label(plan) }.sort.first(200)

        {
          "rows" => @rows.length,
          "entries_to_create" => @planned_rows.length,
          "duplicates_skipped" => @duplicate_rows,
          "zero_hour_skipped" => @zero_hour_rows,
          "clients" => { "existing" => existing_clients, "to_create" => new_clients },
          "projects" => { "existing" => existing_projects, "to_create" => new_projects },
          "users" => users,
          "date_range" => { "from" => dates.min&.iso8601, "to" => dates.max&.iso8601 },
          "warnings" => @warnings.to_a.sort
        }
      end

      def build_user_summary
        names = @rows.pluck(:user_name).compact_blank.uniq.sort
        matched, unmatched = names.partition { |name| resolved_user(name) }
        matched = matched.index_with { |name| resolved_user(name).email }

        { "matched" => matched, "unmatched" => unmatched.first(200) }
      end

      # The generation is read once, before anything is written, and every row
      # is written against it, so an ownership change at any point stops the
      # import instead of letting later rows follow the new owner. Each row is
      # its own gateway transaction: a batch transaction would hold the
      # ownership lock across forwarded calls and block a handoff, and its
      # rollback could not undo rows Timekeeping already stored. Refusals other
      # than an invalid row escape and fail the import.
      def persist_entries
        expected_generation = current_generation
        gateway = entry_gateway(import_user)
        create_clients_and_projects
        create_project_members

        @planned_rows.each_with_index do |row, index|
          begin
            create_entry(gateway, row, expected_generation)
          rescue ActiveRecord::RecordInvalid => error
            add_row_error(row, error.record.errors.full_messages.to_sentence)
          end
          persist_progress if ((index + 1) % 200).zero?
        end

        @summary["entries_created"] = @imported_rows
        @summary["entries_failed"] = @failed_rows
      end

      def persist_plan
        data_import.update!(
          total_rows: @rows.length,
          failed_rows: @failed_rows,
          skipped_rows: @zero_hour_rows + @duplicate_rows,
          summary: @summary,
          row_errors: @row_errors
        )
      end

      def create_clients_and_projects
        ActiveRecord::Base.transaction do
          @client_plans.each_value do |plan|
            plan[:record] = plan[:existing] || company.clients.create!(name: plan[:name], currency: plan[:currency])
            plan[:record].undiscard! if plan[:record].discarded?
          end

          @project_plans.each_value do |plan|
            plan[:record] = plan[:existing] || plan[:client][:record].projects.create!(
              name: plan[:name],
              billable: plan[:billable],
              description: project_description(plan)
            )
            plan[:record].undiscard! if plan[:record].discarded?
          end
        end
      end

      def project_description(plan)
        [
          ("Harvest project: #{plan[:source_name]}" if plan[:source_name] != plan[:name]),
          ("Harvest project code: #{plan[:code]}" if plan[:code])
        ].compact.join("\n").presence
      end

      def create_project_members
        pairs = @planned_rows.each_with_object({}) do |row, result|
          result[[row[:project_plan][:record].id, row[:user].id]] ||= row
        end
        existing = ProjectMember.kept.where(project_id: pairs.keys.map(&:first), user_id: pairs.keys.map(&:last))
          .pluck(:project_id, :user_id)
          .to_set

        pairs.each do |(project_id, user_id), row|
          next if existing.include?([project_id, user_id])

          ProjectMember.create!(project_id:, user_id:, hourly_rate: row[:hourly_rate])
        end
      end

      # A missing ownership row is refused the way the gateway refuses it.
      def current_generation
        ownership = TimekeepingOwnership.find_by(id: TimekeepingOwnership::SINGLETON_ID)
        raise Timekeeping::Gateway::OwnershipMoving if ownership.nil?

        ownership.generation
      end

      # @users holds the company's employed users, read when the job started.
      def import_user
        @users.find { |user| user.id == data_import.user_id } ||
          raise(ImportUserNotInCompany, "Data import ##{data_import.id} user is not employed in the company")
      end

      # The job has no request, so identity comes from the data import alone.
      def entry_gateway(actor)
        Timekeeping::Gateway.new(
          context: Timekeeping::WriteContext.new(
            company:, actor:, actor_kind: "import", request_id: SecureRandom.uuid
          )
        )
      end

      def create_entry(gateway, row, expected_generation)
        record_attempted_row(row)
        gateway.import(
          user: row[:user],
          project: row[:project_plan][:record],
          attributes: {
            duration: row[:duration],
            work_date: row[:work_date],
            note: row[:note],
            bill_status: row[:bill_status],
            source: "import",
            source_metadata: { tool: "harvest" }
          },
          idempotency_key: row_idempotency_key(row),
          expected_generation:
        )
        @imported_rows += 1
      end

      # Saved before the write, and kept across runs, so no failure between the
      # write and this record (a crash, a lost answer from Timekeeping) can
      # leave a written row unrecorded. A recorded row whose write never
      # happened has no stored match to take, so the rerun writes it.
      def record_attempted_row(row)
        DataImport.where(id: data_import.id)
          .where.not("? = ANY(attempted_rows)", row[:row])
          .update_all(["attempted_rows = array_append(attempted_rows, ?)", row[:row]])
      end

      # The same row of the same data import always gives the same key, so a
      # rerun replays a create Timekeeping already stored instead of writing it
      # twice.
      def row_idempotency_key(row)
        digest = Digest::SHA256.hexdigest(JSON.generate(row.slice(*ROW_KEY_FIELDS).transform_values(&:to_s)))
        Digest::UUID.uuid_v5(Timekeeping::EntryWriteClient::IDEMPOTENCY_NAMESPACE,
                             "harvest-import/#{data_import.id}/#{digest}")
      end

      def persist_progress
        data_import.update!(imported_rows: @imported_rows, failed_rows: @failed_rows, row_errors: @row_errors)
      end

      def complete_import
        imported_rows = data_import.dry_run? ? 0 : @imported_rows
        DataImport.transaction do
          data_import.update!(
            status: "completed",
            finished_at: Time.current,
            total_rows: @rows.length,
            imported_rows:,
            failed_rows: @failed_rows,
            skipped_rows: @zero_hour_rows + @duplicate_rows,
            summary: @summary,
            row_errors: @row_errors
          )
          Rails.event.notify(Imports::Completed.new(data_import))
        end
        data_import.file.purge_later unless data_import.dry_run?
      end

      def duplicate_key(user_id, project_id, work_date, duration, note)
        Digest::SHA256.hexdigest([user_id, project_id, work_date.to_date, duration.to_f, note].join("|"))
      end

      def project_label(plan)
        "#{plan[:client][:name]} / #{plan[:name]}"
      end

      def key(value)
        value.to_s.strip.downcase
      end
  end
end
