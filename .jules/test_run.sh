#!/bin/bash
export DISPLAY=:99
Xvfb :99 -screen 0 1280x800x24 > /dev/null 2>&1 &
XVFB_PID=$!
sleep 2

flutter build linux

./build/linux/x64/release/bundle/mlocate_explorer &
APP_PID=$!
sleep 5

import -window root .jules/screenshot1.png

kill $APP_PID
kill $XVFB_PID
