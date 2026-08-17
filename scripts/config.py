#!/usr/bin/env python3
"""Emit values from config/config.yaml for the shell scripts.

The YAML config is read from stdin (so the shell opens the file and we never
pass a filesystem path into Python -- native Windows interpreters can't resolve
the Git Bash "/c/..." paths the scripts produce).

Usage:
  config.py region   < config/config.yaml   -> the AWS region
  config.py prefix   < config/config.yaml   -> the stack name prefix
  config.py tags     < config/config.yaml   -> one "Key=Value" line per tag
  config.py stacks   < config/config.yaml   -> one "name|template|parameters"
                                               line per stack, in deploy order
"""
import sys
import yaml


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: config.py <region|prefix|tags|stacks>")
    field = sys.argv[1]
    cfg = yaml.safe_load(sys.stdin) or {}

    if field == "region":
        print(cfg.get("region", ""))
    elif field == "prefix":
        print(cfg.get("stackPrefix", ""))
    elif field == "tags":
        for key, value in (cfg.get("tags") or {}).items():
            print(f"{key}={value}")
    elif field == "stacks":
        for stack in cfg.get("stacks") or []:
            print(f"{stack['name']}|{stack['template']}|{stack.get('parameters', '')}")
    else:
        sys.exit(f"unknown field: {field}")


if __name__ == "__main__":
    main()
