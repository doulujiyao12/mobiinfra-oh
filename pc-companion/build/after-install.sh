#!/bin/sh
set -eu
mkdir -p /usr/local/bin
ln -sfn '/opt/${sanitizedProductName}/resources/bin/clawmate-codex' /usr/local/bin/clawmate-codex
