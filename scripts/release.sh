#!/bin/bash

set -e

if [ "$#" -ne 1 ]; then
    echo "usage: ./scripts/release.sh VERSION"
    exit 1
fi

VERSION=$1
echo -n "$VERSION" > VERSION

./scripts/libcsdfgen.sh

git add VERSION
git commit -m "$VERSION"
git tag $VERSION

git push
git push origin tag $VERSION

echo "Continue on the GitHub repository's release page to create a new release with tag $VERSION. You will need to upload the release-${VERSION}/*.tar.gz binaries manually."
