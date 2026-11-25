#!/usr/bin/env bash
# Builds the demo: compiles the Java classes, generates JDemo.pas, compiles the Pascal test.
set -euo pipefail
cd "$(dirname "$0")"
FPC=${FPC:-$HOME/Software/fpcupdeluxe/fpc/bin/x86_64-linux/fpc.sh}
mkdir -p build/gen
javac -d java java/demo/*.java
java generator/src/pascaljavabridge/BindingGenerator.java --unit JDemo --out build/gen --cp java \
  'demo.*' \
  java.util.ArrayList java.util.List java.util.Iterator java.lang.StringBuilder \
  java.lang.Runnable java.lang.Throwable java.util.HashMap java.util.Map 'java.util.Map$Entry' \
  java.util.Comparator java.util.function.Function
"$FPC" -O2 -vwn -FUbuild -Furuntime -Fubuild/gen -obuild/TestBindings test/TestBindings.pas
