# Contract: Store schema v7 (035)

- `Migrations.current_version/0`: 6 → 7.
- Migration `{7, "append speckit_run.continue_restore_failure", &add_continue_restore_failure/0}`:
  `:mnesia.transform_table(:speckit_run, fn row -> append nil end, @run_v7_attributes)`.
  A **transform**, not a refusal: v6 rows are readable; the fact did not
  exist when they were written.
- `Store.Schema` `:speckit_run` attributes gain `:continue_restore_failure`
  as the **last** attribute (after `:schema_version`), matching a plain
  tuple-append transform exactly as v3/v4 did for `feature_run`;
  `Records.Run` appends the field last too so `encode/decode` round-trip.
- `Records.Run` struct + type gain
  `continue_restore_failure: %{refusal: String.t(), restore_error: String.t(), at: DateTime.t()} | nil`.
- `Store.Export` includes the field (constitution: record exportable without
  Mnesia).
- No row of any other table is touched. Storage type unchanged (`disc_copies`).
- Migration test: a v6 store boots to v7 with every run row's field `nil`;
  a v8-or-newer store still fails loud (unchanged behaviour).
