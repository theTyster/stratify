import Stratify
import Stratify.Cli

open Stratify Stratify.Cli

def main (args : List String) : IO UInt32 := do
  match args with
  | [] => IO.print usage; return 0
  | cmd :: rest =>
    match cmd with
    | "record" => record
    | "status" => status (hasFlag rest "--json")
    | "plan" => plan rest
    | "claim" => claim rest
    | "gc" => gc rest
    | "install-sensor" => installSensor
    | "help" | "--help" | "-h" => IO.print usage; return 0
    | other =>
      IO.eprintln s!"stratify: unknown command '{other}'"
      IO.eprint usage
      return 2
