#!/bin/bash
# Serves the Orbit demo site on http://localhost:4747 for trying OpenTraffic's live collaboration.
cd "$(dirname "$0")" && exec python3 -m http.server "${1:-4747}" --bind 127.0.0.1
