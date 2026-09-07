#!/usr/bin/env python3
# =============================================================================================
# IBM Confidential
# (C) Copyright IBM Corp. 2026
# The source code for this program is not published or otherwise divested of its trade secrets,
# irrespective of what has been deposited with the U.S. Copyright Office.
# =============================================================================================
"""
zone_region_map_utils.py
------------------------
Utility module for mapping VPC physical zones to regions for secret provisioning.

Responsibilities:
  1. Fetch vpcPhysicalZoneList.md from the vpc-zonemap GitHub repo (always latest).
  2. Parse the Integration / Staging / Production sections of the file.
  3. Canonicalise region labels:
       - "us-south (7x1)"  → "us-south-7x1"
       - "us-south (7x3)"  → "us-south-7x3"
       - "us-south (ngdc)" → "us-south-ngdc"
       - everything else   → stripped of whitespace (e.g. "us-east", "us-south-test")
  4. Expose two public functions:
       get_secret_targets(env, deployment_targets_config)
       build_secret_name(secret_group, secret_name, secret_type, region, zone)

  5. CLI entry-point for use from shell scripts — prints JSON to stdout.

Applicable secret types:
  - global   (default / not set) → provisioned once, NO zone-map expansion needed.
  - regional → provisioned once per REGION in the target env.
  - zonal    → provisioned once per ZONE in the target env.
  Only 'regional' and 'zonal' entries ever reach this utility.

Account boundary:
  - Development account  → integration environment only.
  - Production account   → staging + production environments.

Usage (as a library):
    from zone_region_map_utils import get_secret_targets, build_secret_name

Usage (from shell):
    python3 zone_region_map_utils.py \\
        --env integration \\
        --deployment-targets-json '<json>' \\
        --github-token $GITHUB_TOKEN
    # → prints JSON list of {zone, region, size} dicts
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.request
import urllib.error
from typing import Any

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# GitHub Enterprise API endpoint to fetch vpcPhysicalZoneList.md content.
# The script fetches the file *raw* so it always gets the latest version.
ZONEMAP_REPO_OWNER = "nextgen-environments"
ZONEMAP_REPO_NAME  = "vpc-zonemap"
ZONEMAP_FILE_PATH  = "vpcPhysicalZoneList.md"
ZONEMAP_BRANCH     = "main"

# GitHub Enterprise base URL (override via env var GHE_BASE_URL if needed)
GHE_BASE_URL = os.environ.get("GHE_BASE_URL", "https://github.ibm.com")

# Section heading pattern in the Markdown file
_SECTION_HEADING_RE = re.compile(r"^##\s+(.+)$", re.MULTILINE)

# Table row pattern: | optional-text | universal-name | mzone | dc |
# Rows with no universal name (region header rows) have an empty 2nd cell.
_TABLE_ROW_RE = re.compile(
    r"^\|\s*(.*?)\s*\|\s*(.*?)\s*\|\s*(.*?)\s*\|\s*(.*?)\s*\|"
)

# Normalise a raw region label from the Markdown table into a canonical slug.
# e.g. "us-south (7x1)" → "us-south-7x1"
#      "us-south (ngdc)" → "us-south-ngdc"
#      "us-south-test"   → "us-south-test"
def _canonicalise_region(raw: str) -> str:
    # Strip parenthetical suffix like " (7x1)" or " (ngdc)"
    m = re.match(r"^(.+?)\s*\((.+?)\)\s*$", raw.strip())
    if m:
        base   = m.group(1).strip().rstrip("-")
        suffix = m.group(2).strip()
        return f"{base}-{suffix}"
    return raw.strip()


# ---------------------------------------------------------------------------
# Fetch vpcPhysicalZoneList.md from GitHub Enterprise
# ---------------------------------------------------------------------------

def _fetch_zonemap_content(github_token: str | None = None) -> str:
    """
    Fetch the raw content of vpcPhysicalZoneList.md from the vpc-zonemap repo.
    Raises RuntimeError on failure.
    """
    token = github_token or os.environ.get("GITHUB_TOKEN") or os.environ.get("GHE_TOKEN")

    # Raw content endpoint via GitHub Enterprise API v3
    api_url = (
        f"{GHE_BASE_URL}/api/v3/repos/{ZONEMAP_REPO_OWNER}/{ZONEMAP_REPO_NAME}"
        f"/contents/{ZONEMAP_FILE_PATH}?ref={ZONEMAP_BRANCH}"
    )

    req = urllib.request.Request(api_url)
    req.add_header("Accept", "application/vnd.github.v3.raw")
    if token:
        req.add_header("Authorization", f"token {token}")

    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        raise RuntimeError(
            f"Failed to fetch {ZONEMAP_FILE_PATH} from {api_url}: "
            f"HTTP {exc.code} {exc.reason}"
        ) from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(
            f"Network error fetching {ZONEMAP_FILE_PATH}: {exc.reason}"
        ) from exc


# ---------------------------------------------------------------------------
# Parse zone map from Markdown content
# ---------------------------------------------------------------------------

def _parse_zonemap(content: str) -> dict[str, dict[str, list[str]]]:
    """
    Parse vpcPhysicalZoneList.md and return a nested dict:

        {
          "integration": {
            "us-south-7x1": ["us-south-dal10-int-a", "us-south-dal12-int-a", ...],
            "us-south-test": [...],
            ...
          },
          "staging": { ... },
          "production": { ... },
        }

    Region labels in the table are canonicalised (parenthetical stripped).
    The "Pre-Integration" section is intentionally ignored.

    File structure note:
    The production table lives inside the "## Overview" section (it follows the
    overview prose under "Production Zones" plain text).  The Integration and
    Staging tables each have their own "## Integration" / "## Staging" headings.
    """
    # Split file into sections by "## Heading"
    sections: dict[str, str] = {}
    headings = list(_SECTION_HEADING_RE.finditer(content))
    for idx, match in enumerate(headings):
        heading = match.group(1).strip()
        start   = match.end()
        end     = headings[idx + 1].start() if idx + 1 < len(headings) else len(content)
        sections[heading.lower()] = content[start:end]

    # Map heading names → canonical env keys.
    # "## Production" heading is being added to vpc-zonemap via PR —
    # once merged the production table will be picked up automatically here.
    env_mapping = {
        "production":  "production",
        "integration": "integration",
        "staging":     "staging",
    }

    result: dict[str, dict[str, list[str]]] = {
        "integration": {},
        "staging": {},
        "production": {},
    }

    for heading_lower, block in sections.items():
        if heading_lower in env_mapping:
            env_key = env_mapping[heading_lower]
            result[env_key] = _parse_region_zone_table(block)
        # Silently skip "pre-integration" and other unrecognised sections

    return result


def _parse_region_zone_table(block: str) -> dict[str, list[str]]:
    """
    Parse a Markdown table block and return { canonical_region: [zone, ...] }.
    Rows where the 'Universal Name' cell is empty are region-header rows.
    Rows where the 'Universal Name' cell is non-empty are zone rows.
    """
    region_zones: dict[str, list[str]] = {}
    current_region: str | None = None

    for line in block.splitlines():
        m = _TABLE_ROW_RE.match(line)
        if not m:
            continue

        col1 = m.group(1).strip()  # Region column
        col2 = m.group(2).strip()  # Universal Name column

        # Skip header rows (contain "Region" or "------")
        if col1.lower() in ("region", "------") or col2.lower() in ("universal name", "------"):
            continue

        if col2 == "":
            # Region-header row — update current region
            if col1:
                current_region = _canonicalise_region(col1)
                if current_region not in region_zones:
                    region_zones[current_region] = []
        else:
            # Zone row — append zone to current region
            if current_region and col2:
                region_zones[current_region].append(col2)

    return region_zones


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def get_zone_map(github_token: str | None = None) -> dict[str, dict[str, list[str]]]:
    """
    Fetch and parse the latest vpcPhysicalZoneList.md from GitHub.
    Returns the full zone map for all environments.

    Raises RuntimeError if the file cannot be fetched.
    """
    content = _fetch_zonemap_content(github_token)
    return _parse_zonemap(content)


def get_secret_targets(
    env: str,
    deployment_targets_config: dict[str, Any],
    zone_map: dict[str, dict[str, list[str]]],
) -> list[dict[str, str]]:
    """
    Resolve the list of provisioning targets for a given environment, applying
    the `targets`, `type`, `exclude`, and `override_size` rules from the
    deployment_targets config section.

    Args:
        env:                       "integration", "staging", or "production".
        deployment_targets_config: the dict under deployment_targets.CD.<env>
                                   from the onboarding.yaml.
        zone_map:                  the full zone map (from get_zone_map()).

    Returns:
        A list of dicts. Each dict represents one secret provisioning target:
          {
            "region": str,        # canonical region id
            "zone":   str | None, # zone universal name (None for regional targets)
            "size":   str,        # resolved size (override or default)
          }

        - For type=zonal:    one entry per zone in each included region.
        - For type=regional: one entry per region (zone=None).
        - global secrets do NOT need to call this function; return [] for them.
    """
    env_zones = zone_map.get(env, {})
    if not env_zones:
        return []

    targets_cfg   = deployment_targets_config.get("targets", "all")
    secret_type   = deployment_targets_config.get("type", "zonal")
    default_size  = deployment_targets_config.get("default_size", "small")
    exclude_list  = deployment_targets_config.get("exclude", []) or []
    override_list = deployment_targets_config.get("override_size", []) or []

    # Build override lookup: target_name → size
    overrides: dict[str, str] = {}
    for entry in override_list:
        if isinstance(entry, dict) and "target" in entry and "size" in entry:
            overrides[entry["target"]] = entry["size"]

    # Determine which regions to include
    import sys as _sys  # local import to avoid polluting module namespace

    if targets_cfg == "all":
        included_regions = list(env_zones.keys())

    elif isinstance(targets_cfg, list):
        if not targets_cfg:
            print(
                f"WARNING: deployment_targets.CD.{env}.targets is an empty list — "
                f"no secrets will be provisioned for {env}. "
                f"Set targets: all to provision for all regions.",
                file=_sys.stderr,
            )
        included_regions = []
        for r in targets_cfg:
            if r in env_zones:
                included_regions.append(r)
            else:
                print(
                    f"WARNING: targets entry '{r}' for env={env} is not a known region "
                    f"in vpcPhysicalZoneList.md — skipping. "
                    f"Known regions: {sorted(env_zones.keys())}",
                    file=_sys.stderr,
                )

    else:
        # Single string value — validate it
        if targets_cfg in env_zones:
            included_regions = [targets_cfg]
        else:
            print(
                f"WARNING: targets value '{targets_cfg}' for env={env} is not a known "
                f"region in vpcPhysicalZoneList.md — no secrets will be provisioned. "
                f"Known regions: {sorted(env_zones.keys())}",
                file=_sys.stderr,
            )
            included_regions = []

    # Build a complete set of all known zones across all regions for validation
    all_known_zones = {
        zone
        for zones in env_zones.values()
        for zone in zones
    }

    # Validate every exclude entry — warn if it matches neither a known region
    # nor a known zone Universal Name so teams catch typos immediately.
    for excl in exclude_list:
        if excl not in env_zones and excl not in all_known_zones:
            print(
                f"WARNING: exclude entry '{excl}' for env={env} is not a known region "
                f"or zone Universal Name in vpcPhysicalZoneList.md — it will have no effect. "
                f"Known regions: {sorted(env_zones.keys())}",
                file=_sys.stderr,
            )
        # For regional type, excluding a zone name is meaningless — warn explicitly
        elif secret_type == "regional" and excl in all_known_zones and excl not in env_zones:
            print(
                f"WARNING: exclude entry '{excl}' for env={env} is a zone Universal Name "
                f"but type=regional provisions per-region, not per-zone — "
                f"this exclude has no effect. To skip a region, use its region name instead.",
                file=_sys.stderr,
            )

    # Apply excludes:
    #   - Always filter regions (works for both type=zonal and type=regional)
    #   - For type=zonal, also filter individual zones inside the loop below
    excluded = set(exclude_list)
    included_regions = [r for r in included_regions if r not in excluded]

    # Warn if excludes wiped out a non-empty set of regions (not already warned above)
    if not included_regions and exclude_list and targets_cfg:
        print(
            f"WARNING: After applying excludes, no regions remain for env={env}. "
            f"Check your exclude list: {exclude_list}",
            file=_sys.stderr,
        )

    results: list[dict[str, str]] = []

    if secret_type == "regional":
        # Regional: one secret per region — zone-level exclusion is not applicable
        for region in included_regions:
            size = overrides.get(region, default_size)
            results.append({"region": region, "zone": None, "size": size})

    else:  # zonal (default)
        # Zonal: one secret per zone — exclude can be a region name (skip all its zones)
        # or a zone Universal Name (skip that specific zone only)
        for region in included_regions:
            for zone in env_zones.get(region, []):
                if zone in excluded:
                    continue
                size = overrides.get(zone, overrides.get(region, default_size))
                results.append({"region": region, "zone": zone, "size": size})

    return results


def build_secret_name(
    secret_group: str,
    secret_name: str,
    secret_type: str,
    region: str | None = None,
    zone: str | None = None,
) -> str:
    """
    Build the full secret label according to the naming convention:

        global:   <secret_group>-<secret_name>
        regional: <secret_group>-<region>-<secret_name>
        zonal:    <secret_group>-<universal_name>-<secret_name>

    For zonal secrets the <AZ> placeholder in the convention maps to the full
    Universal Name from vpcPhysicalZoneList.md (e.g. "us-south-dal10-int-a").
    This already encodes region + data-centre + env + env-letter/number, so it
    is used directly — no region prefix is added separately to avoid redundancy.

    Examples:
        zonal:    sg-uuc-myteam-us-south-dal10-int-a-my-secret
        regional: sg-uuc-myteam-us-south-7x1-my-secret
        global:   sg-uuc-myteam-my-secret
    """
    secret_type = (secret_type or "global").lower()

    if secret_type == "zonal":
        if not zone:
            raise ValueError(f"zone (Universal Name) is required for zonal secret: {secret_name}")
        # The Universal Name already contains region+dc+env+letter, e.g.
        # "us-south-dal10-int-a" — use it directly as the unique zone identifier.
        full_name = f"{secret_group}-{zone}-{secret_name}"

    elif secret_type == "regional":
        if not region:
            raise ValueError(f"region is required for regional secret: {secret_name}")
        full_name = f"{secret_group}-{region}-{secret_name}"

    else:  # global
        full_name = f"{secret_group}-{secret_name}"

    return full_name


# ---------------------------------------------------------------------------
# CLI entry-point
# ---------------------------------------------------------------------------

def _cli() -> None:
    """
    Command-line interface for use from shell scripts.

    Modes:
      get-targets  → print JSON list of {region, zone, size} provisioning targets.
      build-name   → print a single secret label string.
      get-zonemap  → print the full JSON zone map for one or all environments.
    """
    parser = argparse.ArgumentParser(
        description="VPC Zone/Region Map Utilities for Secret Provisioning"
    )
    sub = parser.add_subparsers(dest="command", required=True)

    # ── get-targets ──────────────────────────────────────────────────────────
    p_targets = sub.add_parser(
        "get-targets",
        help="Resolve provisioning targets for an environment.",
    )
    p_targets.add_argument("--env", required=True,
                           choices=["integration", "staging", "production"],
                           help="Target environment")
    p_targets.add_argument("--deployment-targets-json", required=True,
                           help="JSON string of the deployment_targets.CD.<env> config block")
    p_targets.add_argument("--github-token",
                           default=os.environ.get("GITHUB_TOKEN") or os.environ.get("GHE_TOKEN"),
                           help="GitHub Enterprise token (default: $GITHUB_TOKEN/$GHE_TOKEN)")

    # ── build-name ───────────────────────────────────────────────────────────
    p_name = sub.add_parser(
        "build-name",
        help="Build a single secret label string.",
    )
    p_name.add_argument("--secret-group",  required=True)
    p_name.add_argument("--secret-name",   required=True)
    p_name.add_argument("--secret-type",   required=True, choices=["zonal", "regional", "global"])
    p_name.add_argument("--region",        default=None)
    p_name.add_argument("--zone",          default=None)

    # ── get-zonemap ──────────────────────────────────────────────────────────
    p_map = sub.add_parser(
        "get-zonemap",
        help="Print the full zone map (or a single env slice) as JSON.",
    )
    p_map.add_argument("--env", default=None,
                       choices=["integration", "staging", "production"],
                       help="If set, return only this environment's slice.")
    p_map.add_argument("--github-token",
                       default=os.environ.get("GITHUB_TOKEN") or os.environ.get("GHE_TOKEN"),
                       help="GitHub Enterprise token")

    args = parser.parse_args()

    # ── dispatch ─────────────────────────────────────────────────────────────
    if args.command == "build-name":
        try:
            label = build_secret_name(
                secret_group=args.secret_group,
                secret_name=args.secret_name,
                secret_type=args.secret_type,
                region=args.region,
                zone=args.zone,
            )
            print(label)
        except ValueError as exc:
            print(f"ERROR: {exc}", file=sys.stderr)
            sys.exit(1)

    elif args.command in ("get-targets", "get-zonemap"):
        token = getattr(args, "github_token", None)
        try:
            zone_map = get_zone_map(token)
        except RuntimeError as exc:
            print(f"ERROR: {exc}", file=sys.stderr)
            sys.exit(1)

        if args.command == "get-zonemap":
            output = zone_map.get(args.env) if args.env else zone_map
            print(json.dumps(output, indent=2))

        else:  # get-targets
            try:
                dt_config = json.loads(args.deployment_targets_json)
            except json.JSONDecodeError as exc:
                print(f"ERROR: Invalid JSON for --deployment-targets-json: {exc}", file=sys.stderr)
                sys.exit(1)

            targets = get_secret_targets(args.env, dt_config, zone_map)
            print(json.dumps(targets, indent=2))


if __name__ == "__main__":
    _cli()
