from pathlib import Path
import subprocess


DRIVER = Path(__file__).parents[1] / ".asv" / "benchmark-driver"


def run_case(case):
    subprocess.run(
        [DRIVER, case],
        check=True,
        stdout=subprocess.DEVNULL,
    )


def time_json_parse():
    run_case("json-parse")


def time_json_round_trip():
    run_case("json-round-trip")


def time_python_text_split():
    run_case("python-text-split")


def time_shell_quote():
    run_case("shell-quote")


def time_log_list_rename():
    run_case("log-list-rename")
