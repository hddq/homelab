#!/usr/bin/env bash

log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

error() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] \e[31mERROR:\e[0m $*" >&2
}
