defmodule SpeckitOrchestrator.AnalyzeResultTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.AnalyzeResult

  test "parses a clean single JSON object" do
    json = ~s({"summary":"ok","findings":[{"severity":"low","title":"nit"}]})
    assert {:ok, r} = AnalyzeResult.parse(json)
    assert r.summary == "ok"
    assert length(r.findings) == 1
    refute r.critical?
  end

  test "critical severity sets critical?" do
    json = ~s({"summary":"bad","findings":[{"severity":"critical","title":"float money"}]})
    assert {:ok, r} = AnalyzeResult.parse(json)
    assert r.critical?
    assert AnalyzeResult.critical?(r)
  end

  test "blocker severity also counts as critical (case-insensitive)" do
    json = ~s({"findings":[{"severity":"BLOCKER","title":"x"}]})
    assert {:ok, r} = AnalyzeResult.parse(json)
    assert r.critical?
  end

  test "empty findings is a clean pass" do
    assert {:ok, r} = AnalyzeResult.parse(~s({"summary":"clean","findings":[]}))
    assert r.findings == []
    refute r.critical?
  end

  test "recovers JSON from a fenced block with trailing prose" do
    transcript = """
    Here is my analysis of the spec.

    ```json
    {"summary":"has issue","findings":[{"severity":"critical","title":"cents"}]}
    ```

    That concludes the review.
    """

    assert {:ok, r} = AnalyzeResult.parse(transcript)
    assert r.critical?
    assert r.summary == "has issue"
  end

  test "recovers JSON embedded mid-transcript" do
    transcript =
      "Analysis complete. {\"summary\":\"s\",\"findings\":[]} — thanks for reading!"

    assert {:ok, r} = AnalyzeResult.parse(transcript)
    assert r.findings == []
  end

  test "picks the LAST object carrying findings when several are present" do
    transcript = """
    {"summary":"draft","findings":[{"severity":"low","title":"old"}]}
    revised:
    {"summary":"final","findings":[{"severity":"critical","title":"new"}]}
    """

    assert {:ok, r} = AnalyzeResult.parse(transcript)
    assert r.summary == "final"
    assert r.critical?
  end

  test "no JSON at all is a failure" do
    assert {:error, :no_analyze_json} = AnalyzeResult.parse("No structured output here.")
  end

  test "malformed JSON is a failure, never a silent pass" do
    assert {:error, :no_analyze_json} =
             AnalyzeResult.parse(~s({"findings": [ {"severity": "critical" ))
  end

  test "findings present but not a list is an explicit error" do
    assert {:error, {:invalid_findings, "nope"}} =
             AnalyzeResult.parse(~s({"summary":"x","findings":"nope"}))
  end

  test "object without a findings key is not a valid analyze result" do
    assert {:error, :no_analyze_json} = AnalyzeResult.parse(~s({"summary":"x"}))
  end
end
