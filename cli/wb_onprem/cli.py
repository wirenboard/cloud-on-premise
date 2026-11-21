import argparse
import sys
import traceback

from . import __version__, check_update, core, doctor, status

# name -> module with HELP, add_arguments(parser) and build(directory, args) -> report
COMMANDS = {"status": status, "doctor": doctor, "check-update": check_update}


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        self.print_usage(sys.stderr)
        self.exit(core.EXIT_START_ERROR, f"{self.prog}: error: {message}\n")


def build_parser():
    # SUPPRESS keeps a flag given before the command from being reset by the subparser default.
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--dir", default=argparse.SUPPRESS,
                        help=f"installation directory (default: $WB_ONPREM_DIR, the current directory, "
                             f"dir= in {core.CONFIG_PATH}, {core.DEFAULT_DIR})")
    common.add_argument("--json", action="store_true", default=argparse.SUPPRESS, help="machine-readable output")
    p = _Parser(prog="wb-onprem", parents=[common],
                description="Maintenance utility for Wiren Board on-premise. "
                            "Exit codes: 0 ok, 1 warn, 2 fail, 3 cannot start.")
    p.add_argument("--version", action="version", version=f"wb-onprem {__version__}")
    sub = p.add_subparsers(dest="command", metavar="command")
    for name, command in COMMANDS.items():
        command.add_arguments(sub.add_parser(name, parents=[common], help=command.HELP))
    return p


def main(argv=None):
    parser = build_parser()
    try:
        args = parser.parse_args(argv)
    except SystemExit as e:
        return e.code
    if not args.command:
        parser.print_help(sys.stderr)
        return core.EXIT_START_ERROR
    try:
        directory = core.find_dir(getattr(args, "dir", None))
        report = COMMANDS[args.command].build(directory, args)
    except core.CliError as e:
        print(f"wb-onprem: {e}", file=sys.stderr)
        return core.EXIT_START_ERROR
    except Exception:
        traceback.print_exc()
        return core.EXIT_START_ERROR
    core.emit(report, getattr(args, "json", False))
    return core.exit_code(report["status"])
