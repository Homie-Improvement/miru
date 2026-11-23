# frozen_string_literal: true

require "yaml"

# Loads the two seeded companies into the live Timekeeping application for the
# tenant guard. TimekeepingDatabaseReset.reset! leaves Timekeeping with only
# its admission row, so without this load every cross-tenant probe would find
# nothing because nothing exists, not because the company filter held.
#
# The seed travels the real checkpoint path: the legacy source exports it from
# the monolith, and the Timekeeping store loads it over HTTP. Timekeeping
# refuses a load unless admission is fenced, so admission is fenced first and
# restored at the owner state's generation afterwards, even when the load fails.
module TenantGuardSeedLoad
  OWNER_STATE = "timekeeping"

  # The admission row read back after the load did not hold the expected
  # generation, so the applications would refuse the guard's requests.
  class AdmissionMismatch < StandardError
    def initialize(expected:, actual:)
      super("Timekeeping admission is generation #{actual.inspect} after the seed load, " \
            "expected #{expected.inspect}")
    end
  end

  module_function

  # runtime: the IntegratedRuntime of the example (timekeeping_url and
  # credentials.service_token are read). timekeeping_database_url: the
  # Timekeeping database, read directly to check the admission generation.
  # Returns the loaded checkpoint.
  def load!(runtime:, timekeeping_database_url: ENV.fetch(TimekeepingDatabaseReset::DATABASE_URL_KEY),
            captured_at: Time.current.utc)
    generation = admission_generation
    checkpoint = export_checkpoint(generation:, captured_at:)
    store = Timekeeping::Handoff::TimekeepingStore.new(
      base_url: runtime.timekeeping_url, token: runtime.credentials.service_token
    )
    load_while_fenced(store, checkpoint, generation:)
    require_admission_generation!(timekeeping_database_url, generation)
    checkpoint
  end

  def admission_generation
    TimekeepingOwnerState.fetch(OWNER_STATE).fetch(:admission_generation)
  end

  # LegacySource#export opens its own repeatable-read transaction, so this
  # must not run inside a transaction the caller already opened.
  def export_checkpoint(generation:, captured_at:)
    Timekeeping::Handoff::LegacySource.new(
      connection: ActiveRecord::Base.connection,
      recorded_disposition: YAML.load_file(Timekeeping::SeedDispositionRecorder::DEFAULT_PATH)
    ).export(generation:, captured_at:).fetch(:checkpoint)
  end

  # The load leaves the entries id sequence alone, so it is moved above the
  # highest loaded id; otherwise the next entry Timekeeping creates would
  # collide with a seeded id.
  def load_while_fenced(store, checkpoint, generation:)
    load_error = nil
    begin
      store.fence_admission
      store.load_checkpoint(checkpoint)
      store.advance_entry_id_sequence(above: highest_entry_id(checkpoint))
    rescue StandardError => error
      load_error = error
      raise
    ensure
      restore_admission(store, generation, load_error)
    end
  end

  # An admit failure propagates only when nothing else failed first, so it
  # never hides the error that stopped the load.
  def restore_admission(store, generation, earlier_error)
    store.admit(generation:)
  rescue StandardError
    raise unless earlier_error
  end

  def highest_entry_id(checkpoint)
    checkpoint.rows.fetch("entries").map { |row| row.fetch("id") }.max || 0
  end

  # The store has no call that reads the generation back, so the admission
  # row is read from the Timekeeping database itself.
  def require_admission_generation!(timekeeping_database_url, expected)
    actual = read_admission_generation(timekeeping_database_url)
    raise AdmissionMismatch.new(expected:, actual:) unless actual == expected

    nil
  end

  def read_admission_generation(timekeeping_database_url)
    TestDatabaseGuard.require_test_database_url!(timekeeping_database_url)
    name = TimekeepingDatabaseReset.database_name(timekeeping_database_url)
    connection = TimekeepingDatabaseReset.connect(timekeeping_database_url, name)
    raise PG::ConnectionBad, "the Timekeeping database #{name.inspect} does not exist", cause: nil unless connection

    result = connection.exec_params("SELECT generation FROM admission WHERE id = $1",
                                    [TimekeepingDatabaseReset::ADMISSION_ID])
    result.column_values(0).first&.to_i
  ensure
    connection&.close
  end
  private_class_method :export_checkpoint, :load_while_fenced, :restore_admission, :highest_entry_id,
                       :require_admission_generation!, :read_admission_generation
end
