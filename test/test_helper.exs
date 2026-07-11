# Integration tests (@tag :integration) hit the real Claude CLI and cost money —
# excluded by default, run explicitly with `mix test --include integration`.
ExUnit.start(exclude: [:integration])
