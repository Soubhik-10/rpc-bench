#!/usr/bin/env sh
set -eu

BUILD_ROOT="${BUILD_ROOT:-.build/reth-images}"

REPO_A="${REPO_A:-https://github.com/paradigmxyz/reth-oss.git}"
BRANCH_A="${BRANCH_A:-debug-trace-release-inspector}"
IMAGE_A="${IMAGE_A:-reth-debug-trace-release-inspector:latest}"

REPO_B="${REPO_B:-https://github.com/paradigmxyz/reth-oss.git}"
BRANCH_B="${BRANCH_B:-port/nethermind-11755-trace-streaming}"
IMAGE_B="${IMAGE_B:-reth-nethermind-11755-trace-streaming:latest}"

REPO_C="${REPO_C:-https://github.com/ethpandaops/reth-oss.git}"
BRANCH_C="${BRANCH_C:-main}"
IMAGE_C="${IMAGE_C:-reth-ethpandaops:latest}"

clone_or_update() {
  name="$1"
  repo="$2"
  branch="$3"
  dir="$BUILD_ROOT/$name"

  if [ -d "$dir/.git" ]; then
    echo "Updating $name from $repo ($branch)"
    git -C "$dir" fetch origin "$branch"
    git -C "$dir" checkout "$branch"
    git -C "$dir" reset --hard "origin/$branch"
  else
    echo "Cloning $name from $repo ($branch)"
    git clone --branch "$branch" --single-branch "$repo" "$dir"
  fi
}

build_image() {
  name="$1"
  image="$2"
  dir="$BUILD_ROOT/$name"

  echo "Building $image from $dir"
  docker build -t "$image" "$dir"
}

mkdir -p "$BUILD_ROOT"

clone_or_update "debug-trace-release-inspector" "$REPO_A" "$BRANCH_A"
clone_or_update "nethermind-11755-trace-streaming" "$REPO_B" "$BRANCH_B"
clone_or_update "ethpandaops-reth" "$REPO_C" "$BRANCH_C"

build_image "debug-trace-release-inspector" "$IMAGE_A"
build_image "nethermind-11755-trace-streaming" "$IMAGE_B"
build_image "ethpandaops-reth" "$IMAGE_C"

cat <<EOF
Built images:
  $IMAGE_A  ($REPO_A $BRANCH_A)
  $IMAGE_B  ($REPO_B $BRANCH_B)
  $IMAGE_C  ($REPO_C $BRANCH_C)
EOF
