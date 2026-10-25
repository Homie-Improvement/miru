# frozen_string_literal: true

class Timekeeping::V1::EntriesController < ApplicationController
  LIST_FILTERS = %w[from to user_id project_id].freeze

  def index
    entries = Timekeeping::EntriesQuery.visible(**visibility, filters: request.query_parameters.slice(*LIST_FILTERS))
    render json: { entries: entries.map { |entry| Timekeeping::EntryPresenter.call(entry) } }
  end

  def show
    entry = Timekeeping::EntriesQuery.find_visible(params[:entry_id], **visibility)
    return render_reason(:not_found) unless entry

    render json: Timekeeping::EntryPresenter.call(entry)
  end
end
