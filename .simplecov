# frozen_string_literal: true

require "simplecov-cobertura"

SimpleCov.root File.expand_path(__dir__)
SimpleCov.coverage_dir "coverage"
SimpleCov.command_name "tests"
SimpleCov.minimum_coverage line: Integer(ENV.fetch("MINIMUM_COVERAGE", "90"))
SimpleCov.formatters = [
  SimpleCov::Formatter::HTMLFormatter,
  SimpleCov::Formatter::CoberturaFormatter
]
SimpleCov.skip "/tests/"
SimpleCov.skip "/vendor/"
SimpleCov.group "Bash", "*.sh"
