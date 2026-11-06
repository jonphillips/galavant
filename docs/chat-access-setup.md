# Chat Access setup

**Status:** Active · **Summary:** Install and refresh the Galavant chat helper.

The helper is `~/.local/bin/galavant-mcp`. Install or reinstall it after updating the checkout:

```sh
~/code/jon-platform/scripts/install-mcp-helper ~/code/galavant/galavant/GalavantMCP galavant-mcp
```

The `galavant` tunnel uses port 8082. Its tool is `stage_trip_return`. After reinstalling, restart the tunnel and refresh the connector's tools. For the general tunnel and connector setup, see `jon-platform/docs/ios/mcp-access.md`.
