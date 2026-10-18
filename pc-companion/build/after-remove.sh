#!/bin/sh
set -eu
if [ -L /usr/local/bin/clawmate-codex ] && [ "$(readlink /usr/local/bin/clawmate-codex)" = '/opt/${sanitizedProductName}/resources/bin/clawmate-codex' ]; then
  unlink /usr/local/bin/clawmate-codex
fi
