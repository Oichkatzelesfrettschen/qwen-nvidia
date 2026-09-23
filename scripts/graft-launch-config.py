#!/usr/bin/env python3
"""Bind a standalone CUDA session to one validated Graft workflow."""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import stat
import sys
from urllib.parse import urlsplit


def signing_key_bytes(path):
    """Read a bounded regular key file without waiting on special files."""
    descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as handle:
        metadata = os.fstat(handle.fileno())
        if not stat.S_ISREG(metadata.st_mode):
            raise ValueError("MCP composition signing key must be a regular file")
        if metadata.st_uid != os.getuid() or metadata.st_mode & 0o077:
            raise ValueError("MCP composition signing key requires private ownership and mode")
        content = handle.read(8193)
        if not 16 <= len(content) <= 8192:
            raise ValueError("MCP composition signing key length is invalid")
        return content


def composed_profile(mcp, authorization_key_file, selected_profile=None):
    """Bind preserved tool children to the broker profile and signing key."""
    labels = set()
    if selected_profile:
        labels.add(selected_profile)
    signing_key = signing_key_bytes(authorization_key_file)
    profile_fields = ("QWEN_WEB_PROFILE", "QWEN_IMAGE_LANGUAGE_PROFILE",
                      "QWEN_SIDECAR_LANGUAGE_PROFILE")
    key_fields = ("QWEN_WEB_TOKEN_KEY_FILE", "QWEN_IMAGE_TOKEN_KEY_FILE",
                  "QWEN_SIDECAR_TOKEN_KEY_FILE")
    for server_name, server in mcp["mcpServers"].items():
        if not isinstance(server, dict) or not isinstance(server.get("env", {}), dict):
            raise ValueError(f"MCP composition requires an object environment for {server_name}")
        environment = server.get("env", {})
        for field in profile_fields:
            if field in environment:
                value = environment[field]
                if not isinstance(value, str) or not value:
                    raise ValueError(f"MCP composition requires a profile in {server_name}.{field}")
                labels.add(value)
        for field in key_fields:
            if field not in environment:
                continue
            value = environment[field]
            if not isinstance(value, str) or not Path(value).is_absolute():
                raise ValueError(f"MCP composition requires an absolute signing-key path in {server_name}.{field}")
            try:
                key = signing_key_bytes(value)
            except OSError:
                raise ValueError(f"MCP composition cannot read the signing key in {server_name}.{field}") from None
            if key != signing_key:
                raise ValueError(f"MCP composition signing-key mismatch in {server_name}.{field}")
    if any(not isinstance(label, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", label)
           for label in labels):
        raise ValueError("MCP composition requires valid profile identifiers")
    if len(labels) > 1:
        raise ValueError("MCP composition has contradictory broker profiles")
    return next(iter(labels), "graft")


def retained_broker_settings(mcp):
    """Carry the retained tool identities into the authorization broker."""
    settings = {}
    direct_fields = ("QWEN_WEB_PROVIDER", "QWEN_IMAGE_PROFILE", "QWEN_CODING_PROFILE")
    sidecar_fields = {"physics": "QWEN_PHYSICS_PROFILE", "geometry": "QWEN_GEOMETRY_PROFILE"}
    for server_name, server in mcp["mcpServers"].items():
        environment = server.get("env", {})
        for field in direct_fields:
            if field not in environment:
                continue
            value = environment[field]
            if not isinstance(value, str) or not value:
                raise ValueError(f"MCP composition requires {server_name}.{field}")
            if field in settings and settings[field] != value:
                raise ValueError(f"MCP composition has contradictory {field}")
            settings[field] = value
        if "QWEN_SIDECAR_SERVICE" in environment or "QWEN_SIDECAR_PROFILE" in environment:
            service = environment.get("QWEN_SIDECAR_SERVICE")
            if service not in sidecar_fields:
                raise ValueError(f"MCP composition requires a sidecar service in {server_name}")
            field = sidecar_fields[service]
            value = environment.get("QWEN_SIDECAR_PROFILE")
            if not isinstance(value, str) or not value:
                raise ValueError(f"MCP composition requires {server_name}.QWEN_SIDECAR_PROFILE")
            if field in settings and settings[field] != value:
                raise ValueError(f"MCP composition has contradictory {field}")
            settings[field] = value
    for field in ("QWEN_IMAGE_PROFILE", "QWEN_CODING_PROFILE",
                  "QWEN_PHYSICS_PROFILE", "QWEN_GEOMETRY_PROFILE"):
        if field in settings and not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", settings[field]):
            raise ValueError(f"MCP composition requires a valid {field}")
    return settings


def prepare(config_path, base_mcp_path=None, web_profile=None):
    scripts = Path(__file__).resolve().parent
    specification = importlib.util.spec_from_file_location(
        "qwen_graft_workflow", scripts / "graft-workflow.py"
    )
    workflow = importlib.util.module_from_spec(specification)
    sys.modules[specification.name] = workflow
    specification.loader.exec_module(workflow)
    config_path = Path(config_path).resolve(strict=True)
    config = workflow.load_config(config_path)
    endpoint = urlsplit(config["model"]["base_url"])
    if endpoint.hostname != "127.0.0.1":
        raise ValueError("standalone endpoint must use 127.0.0.1")
    if config["model"]["name"] != "qwen-nvidia":
        raise ValueError("standalone serving alias must be qwen-nvidia")
    api_key = Path(config["model"]["api_key_file"])
    if api_key.name != "api.key":
        raise ValueError("session API key must be named api.key")
    state_directory = api_key.parent
    mcp = {"mcpServers": {}}
    if base_mcp_path:
        mcp = json.loads(Path(base_mcp_path).read_text())
    if not isinstance(mcp, dict) or not isinstance(mcp.get("mcpServers"), dict):
        raise ValueError("base MCP configuration requires mcpServers")
    if "qwen_graft" in mcp["mcpServers"]:
        raise ValueError("base MCP configuration already names qwen_graft")
    profile = composed_profile(
        mcp, config["authorization_key_file"],
        os.environ.get("QWEN_WEB_PROFILE") if web_profile is None else web_profile,
    )
    broker_settings = retained_broker_settings(mcp)
    workflow.initialize_storage(config)
    config_path = Path(config["artifact_root"]) / (
        "session-config-" + workflow.hashlib.sha256(workflow.canonical(config)).hexdigest() + ".json"
    )
    if config_path.exists():
        if workflow.read_json(config_path) != config:
            raise ValueError("session configuration snapshot differs")
    else:
        workflow.atomic_json(config_path, config)
    mcp["mcpServers"]["qwen_graft"] = {
        "command": sys.executable,
        "args": [str(scripts / "graft-workflow.py"), "--config", str(config_path), "mcp"],
        "env": {"PYTHON": sys.executable, "PYTHONDONTWRITEBYTECODE": "1",
                "QWEN_GRAFT_SESSION_BARRIER": str(state_directory),
                "QWEN_GPU_ADMISSION_BARRIER": str(state_directory)},
        "timeout_ms": 120000,
    }
    mcp_path = Path(config["artifact_root"]) / (
        "session-mcp-" + workflow.hashlib.sha256(workflow.canonical(mcp)).hexdigest() + ".json"
    )
    if mcp_path.exists():
        if workflow.read_json(mcp_path) != mcp:
            raise ValueError("session MCP snapshot differs")
    else:
        workflow.atomic_json(mcp_path, mcp)
    return {
        "QWEN_GRAFT_CONFIG": str(config_path), "QWEN_GRAFT_MCP_CONFIG": str(mcp_path),
        "QWEN_WEBUI_STATE_DIRECTORY": str(state_directory),
        "QWEN_SERVER_PORT": str(endpoint.port or 80), "QWEN_BIND_HOST": "127.0.0.1",
        "QWEN_REQUIRE_API_KEY": "1", "QWEN_CHAT_TOOLS": "on",
        "QWEN_WEB_BROKER": "1", "QWEN_WEB_PROFILE": profile,
        "QWEN_WEB_TOKEN_KEY_FILE": config["authorization_key_file"],
        "QWEN_WEB_STATE_DIR": str(state_directory / "web"),
        **broker_settings,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("config")
    parser.add_argument("--base-mcp")
    parser.add_argument("--web-profile", help="Existing broker profile; must match preserved MCP children")
    arguments = parser.parse_args()
    try:
        environment = prepare(arguments.config, arguments.base_mcp, arguments.web_profile)
    except (OSError, ValueError) as error:
        parser.exit(2, f"Graft launch configuration refused: {error}\n")
    for name, value in environment.items():
        print(f"export {name}={shlex.quote(str(value))}")


if __name__ == "__main__":
    main()
