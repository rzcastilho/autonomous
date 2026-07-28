# Integration tests (@tag :integration) hit the real Claude CLI and cost money —
# excluded by default, run explicitly with `mix test --include integration`.
#
# The store (018) is machine-global per Mnesia directory, so there is one
# store for the whole suite — booted automatically when the application
# starts, against the tmp `autonomous_root/mnesia` test config in
# config/config.exs (research R14: the default suite never touches
# ~/.autonomous). Remove it on exit so repeated runs never accumulate stale
# schema files.
System.at_exit(fn _status -> File.rm_rf(SpeckitOrchestrator.Config.store_dir()) end)

ExUnit.start(exclude: [:integration])
