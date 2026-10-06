# Synthetic replay of the fretboard-master 014 stall (session 3e935ca9):
# a long verification command hits the CLI's Bash cap and is auto-backgrounded,
# the model starts a watcher, then ends its turn "waiting" — the session
# completes :ok without ever reading the command's output.
#
# Evaluate with `Code.eval_file/1`; returns `[{type, payload}]` tuples.
[
  {:session_started, %{"tools" => ["Bash", "Monitor", "Read"]}},
  {:tool_call,
   %{
     "name" => "Bash",
     "call_id" => "toolu_bash_1",
     "input" => %{"command" => "npm run test:e2e -- --reporter=line", "timeout" => 600_000}
   }},
  {:tool_result,
   %{
     "call_id" => "toolu_bash_1",
     "is_error" => false,
     "output" =>
       "Command did not complete within its 600s timeout and was moved to the background (ID: bx014a). " <>
         "Output is being written to: /tmp/claude-1000/tasks/bx014a.output"
   }},
  {:tool_call,
   %{
     "name" => "Monitor",
     "call_id" => "toolu_mon_1",
     "input" => %{"description" => "watch e2e run"}
   }},
  {:tool_result,
   %{"call_id" => "toolu_mon_1", "is_error" => false, "output" => "Monitor started."}},
  {:output_text_delta, %{"text" => "Waiting for the e2e run to finish."}},
  {:session_completed,
   %{"result" => "Waiting for the e2e run to finish.", "num_turns" => 41, "is_error" => false}}
]
