#!/usr/bin/env bash
set -euo pipefail
: "${THEOS:?Set THEOS to your Theos directory first}"
make clean package FINALPACKAGE=1
ls -lh packages/*.deb
