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

gh release create $VERSION release-$VERSION/*.tar.gz
