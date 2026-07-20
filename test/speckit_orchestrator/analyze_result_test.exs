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

  test "salvages a truncated findings object missing its closing braces" do
    # Model stopped emitting before the final `}` / `]` (observed in a live run).
    transcript = """
    Analysis below.

    {"summary":"halts on money path","findings":[{"severity":"critical","title":"float money","detail":"forbidden","constitution_rule":"P1"}]
    """

    assert {:ok, r} = AnalyzeResult.parse(transcript)
    assert r.critical?
    assert length(r.findings) == 1
    assert r.summary == "halts on money path"
  end

  test "salvages truncation mid-string (closes the string, then the structure)" do
    transcript = ~s({"summary":"ok","findings":[{"severity":"critical","title":"cut off here)

    assert {:ok, r} = AnalyzeResult.parse(transcript)
    assert r.critical?
  end

  test "salvage still recovers the value path from a noisy transcript" do
    transcript = """
    Read all artifacts.

    ## Findings
    prose with braces-free text and a stray ] bracket mention.

    {"summary":"clean","findings":[]
    """

    assert {:ok, r} = AnalyzeResult.parse(transcript)
    refute r.critical?
    assert r.findings == []
  end

  test "salvage does not fabricate: a non-summary truncated object stays a failure" do
    assert {:error, :no_analyze_json} =
             AnalyzeResult.parse(~s({"findings": [ {"severity": "critical" ))
  end

  describe "high? severity" do
    test "a high finding sets high? without setting critical?" do
      transcript = ~s({"summary":"gaps","findings":[{"severity":"high","title":"plan.md missing"}]})

      assert {:ok, r} = AnalyzeResult.parse(transcript)
      assert r.high?
      assert AnalyzeResult.high?(r)
      refute r.critical?
    end

    test "high? is case-insensitive" do
      assert {:ok, r} = AnalyzeResult.parse(~s({"summary":"s","findings":[{"severity":"HIGH"}]}))
      assert r.high?
    end

    test "no findings means neither high? nor critical?" do
      assert {:ok, r} = AnalyzeResult.parse(~s({"summary":"clean","findings":[]}))
      refute r.high?
      refute r.critical?
    end

    # The live-run shape this was added for: analyze reported the design
    # artifacts were missing as `high`, and the feature reached :done anyway.
    test "a critical finding alongside a high one sets both flags" do
      transcript =
        ~s({"summary":"s","findings":[{"severity":"high"},{"severity":"critical"}]})

      assert {:ok, r} = AnalyzeResult.parse(transcript)
      assert r.high?
      assert r.critical?
    end
  end
end
