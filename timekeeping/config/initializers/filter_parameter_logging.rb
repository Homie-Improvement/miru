# frozen_string_literal: true

# An allow-list, not the usual deny-list: every parameter is masked unless
# Timekeeping::LogSafety allows both its name and its value's shape. This also
# masks the query string in the request start line; Timekeeping::RequestLogger
# masks the path segments there.
Rails.application.config.filter_parameters = Timekeeping::LogSafety::PARAMETER_FILTERS.dup
