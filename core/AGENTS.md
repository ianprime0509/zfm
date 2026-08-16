# ZFM core

Core synth, driver, and MML compiler.

## Testing

- Run `zig build test` to run the tests.
- Compiler test cases (`src/Compiler/testdata`) compare compilation results against verified output. Use the CLI to produce the reference data: `zfm -o test-case.json --log-file test-case.log.jsonl --no-fade test-case.zfm`. Error test cases likewise compare against the compiler's error output. Don't forget to add the corresponding test blocks in `src/test.zig` when adding new tests - they are not autodiscovered.
