# Notices and licensing decision

The original source authored for InkFlow is currently private work with all
rights reserved. The repository does not grant a redistribution license for
that material.

`third_party/librime` is a separate work from the Rime project and remains
licensed under its BSD-3-Clause license. Its recursively pinned dependencies
retain their respective notices and license terms. InkFlow's reserved-rights
notice does not replace, restrict, or relicense any third-party work.

This repository currently targets private, local use and does not define a
binary distribution process. Before any future distribution, audit the exact
dependency graph, choose an explicit license for InkFlow-authored material, and
include every notice required by the versions recorded in
`dependencies.lock.json`.
