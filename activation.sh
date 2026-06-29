#!/usr/bin/env bash
# Activation script for pixi environment.
# Sets TRINITY_HOME and adds Trinity binaries to PATH.

export TRINITY_HOME="${PIXI_PROJECT_ROOT:-$(pwd)}"
export PATH="${TRINITY_HOME}/trinity-plugins/BIN:${PATH}"
