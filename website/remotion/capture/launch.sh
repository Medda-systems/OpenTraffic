#!/bin/zsh
# Launches the demo-capture OpenTraffic: isolated data, demo ports only, off-screen windows.
T='<true/>'; F='<false/>'
rm -rf /tmp/ot-capture; mkdir -p /tmp/ot-capture /tmp/ot-demo-home
open -j -n --stdout /tmp/ot-demo/app.log --stderr /tmp/ot-demo/app.log -a /tmp/ot-demo-app/OpenTraffic.app \
  --env CFFIXED_USER_HOME=/tmp/ot-demo-home \
  --env OPENTRAFFIC_CAPTURE=/tmp/ot-capture \
  --env OPENTRAFFIC_DEMO_PORTS=5175,3002,4400 \
  --env OPENTRAFFIC_OPENTUNNEL_PROFILE=opentraffic-demo \
  --args -migratedLegacyDefaults "$T" -hasCompletedOnboarding "$T" -apiEnabled "$T" \
  -apiPort '<integer>47799</integer>' -apiAllowsPublishingWithoutAsking "$T" \
  -notifyWhenReady "$F" -notifyOnFailure "$F" -notifyCollaboration "$F" -autoCopyPublicURL "$F" \
  -dockVisibility windowOnly -globalHotKeysEnabled "$F" -collaborationHostName Ava
