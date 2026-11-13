# Cardiff action-space Meander experiment

Fresh teacher-free BES/TPG search in official CAGE2. Each atomic terminal
stores one Cardiff actor index. The 62 inputs and the three fixed opening
actions match the public Cardiff deployment. On an exhausted Decoy slot the
Controller examines the entire ranking of reachable TPG terminals, skipping
Restore. Monitor handles a graph with no legal alternative. Native BES
admission, paired racing, migration and promotion remain active. The
Semantic-36 specialist worker is outside this flat-action experiment.

Build from pinned local dependencies with Python 3.12 or newer.

    python3 docker/package-context.py --bridge "$BRIDGE_REPO" \
      --cyborg "$CAGE2_REPO" --lisp-sources "$QUICKLISP_SOFTWARE" release.tar.gz
    mkdir release
    tar -xzf release.tar.gz -C release
    sudo docker build -t bes-meander:cardiff-action-space release

    mkdir smoke
    sudo docker run --rm --user "$(id -u):$(id -g)" --env HOME=/tmp \
      --env BES_ISLAND_IP=127.0.0.1 --network none \
      --mount "type=bind,src=$PWD/smoke,dst=/run/bes" \
      bes-meander:cardiff-action-space smoke

The harry launcher runs four islands with separate logs and random seeds
and migrates every 50 generations on a dedicated private ring.

    sudo python3 release/bes/docker/launch-harry.py "$PWD/run"
    tail -f run/island-*/server.log
    sudo docker stop bes-cardiff-{1..4}
