# frozen_string_literal: true

require "json"
require "simplecov-cobertura"

class CoverageJsonFormatter
  def format(result)
    coverage = result.files.to_h do |file|
      relative_path = file.filename.delete_prefix("#{SimpleCov.root}/")
      [
        relative_path,
        {
          covered_lines: file.covered_lines.length,
          total_lines: file.lines_of_code,
          lines_covered_percent: file.covered_percent
        }
      ]
    end

    output = File.join(SimpleCov.coverage_path, "coverage.json")
    File.write(output, JSON.pretty_generate(coverage: coverage))
  end
end

SimpleCov.root File.expand_path(__dir__)
SimpleCov.coverage_dir "coverage"
SimpleCov.command_name "tests"
SimpleCov.minimum_coverage line: Integer(ENV.fetch("MINIMUM_COVERAGE", "90"))
SimpleCov.formatters = [
  SimpleCov::Formatter::HTMLFormatter,
  SimpleCov::Formatter::CoberturaFormatter,
  CoverageJsonFormatter
]
SimpleCov.skip "/tests/"
SimpleCov.skip "/vendor/"
SimpleCov.group "Bash", "*.sh"
