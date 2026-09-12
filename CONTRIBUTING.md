# Contributing

Thank you for contributing! There's a lot that you can do to improve this project.

## Issues

If you have an issue or suggestion, open an issue in [Issues](../../issues). Please try to use the templates provided for bugs and feature requests.

## Formatting

Use standard Bash conventions. Follow [Google's Shell Style Guide](https://google.github.io/styleguide/shellguide.html) where possible. Use `snake_case` for function and variable names.

## Testing

The test suite requires Bash and jq. It mocks PipeWire commands and menu input, so it does not change your live audio routing.

Run all tests with:

```sh
bash tests/run.sh
```

Run only the interactive stream-exclusion regression tests with:

```sh
bash tests/test-stream-exclusion.sh
```

### Coverage

Coverage requires Ruby and Bundler. Install the locked dependencies, run the suite through Bashcov, and enforce the same 90% minimum line coverage used by CI:

```sh
bundle install
TEST_PASSES=3 MINIMUM_COVERAGE=90 bundle exec bashcov --skip-uncovered tests/run.sh
```

The command writes an HTML report to `coverage/index.html`, a Cobertura report to `coverage/coverage.xml`, and a machine-readable summary to `coverage/coverage.json`.

## Pull Requests

When submitting a pull request, please try to follow the pull request template when creating a pull request.
