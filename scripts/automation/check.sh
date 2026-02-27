#!/usr/bin/env bash
set -euo pipefail

if ! tuist generate; then
  exit 10
fi

if ! tuist build; then
  exit 10
fi

if ! tuist test; then
  exit 11
fi
