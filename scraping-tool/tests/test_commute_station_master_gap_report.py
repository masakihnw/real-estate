import json
import os
import subprocess
import sys
from pathlib import Path


def test_gap_report_outputs_summary(tmp_path: Path):
    output_csv = tmp_path / "gap.csv"
    cmd = [
        sys.executable,
        "scraping-tool/scripts/commute_station_master_gap_report.py",
        "--input",
        "data/samples/properties_sample.csv",
        "--stations-csv",
        "configs/commute/stations.csv",
        "--station-master-csv",
        "data/commute/station_master_template.csv",
        "--offices-yaml",
        "configs/commute/offices.yaml",
        "--output-csv",
        str(output_csv),
    ]
    repo_root = Path(__file__).resolve().parents[2]
    completed = subprocess.run(
        cmd,
        cwd=repo_root,
        check=True,
        capture_output=True,
        text=True,
        env={**os.environ, "PYTHONPATH": str(repo_root / "scraping-tool")},
    )

    summary = json.loads(completed.stdout.strip())
    assert summary["candidate_zero_count"] >= 1
    assert output_csv.exists()
