#!/usr/bin/env python3

"""
CI/CD Onboarding YAML Validation Script
This script validates a <service_name>-onboarding.yaml file for completeness and correctness.
"""

import sys
import re
import os
import argparse
import subprocess
from pathlib import Path
from typing import Dict, List, Any, Optional

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML is not installed. Installing...")
    import subprocess
    subprocess.check_call([sys.executable, "-m", "pip", "install", "pyyaml", "--quiet"])
    import yaml

# Color codes
RED = '\033[0;31m'
GREEN = '\033[0;32m'
YELLOW = '\033[1;33m'
BLUE = '\033[0;34m'
NC = '\033[0m'

# Validation counters
errors = 0
warnings = 0
debug_mode = False

# Valid team names
VALID_TEAMS = [
    "Fabric", "DCMS", "SLAD", "Core Services", "COS", "File Block",
    "Network Underlay", "Network Services", "Observability", "PAG",
    "Pentest", "Seceng", "VPC"
]

# Lower-cased for case-insensitive membership checks
_VALID_TEAMS_LOWER = {t.lower(): t for t in VALID_TEAMS}

# Mandatory secret definitions that should not be modified by teams
# Format: {group_name: [{name, description, mandatory}]}
MANDATORY_SECRETS_TEMPLATE = {
    "CI": [
        {"name": "gara-signing-credentials", "description": "GARA code signing credentials", "mandatory": True},
        {"name": "gara-signing-key", "description": "GARA code signing key", "mandatory": True},
        {"name": "mend-org-token", "description": "Mend SAST organization token", "mandatory": True},
        {"name": "mend-user-key", "description": "Mend SAST user key", "mandatory": True},
        {"name": "mend-product-token", "description": "Mend SAST product token", "mandatory": True},
    ],
    "CD": [
        {"name": "service-now-prod-iam-token", "description": "ServiceNow production IAM token", "mandatory": True},
        {"name": "service-now-test-iam-token", "description": "ServiceNow test IAM token", "mandatory": True},
        {"name": "gara-code-signing-certificate", "description": "GARA code signing certificate", "mandatory": True},
    ],
    "common": [
        {"name": "service-functional-id-dev-cloud-apikey", "description": "Service functional ID dev IBM Cloud API key (used for ICR, Secrets Manager, and cloud resources)", "mandatory": True},
        {"name": "service-functional-id-prod-cloud-apikey", "description": "Service functional ID production IBM Cloud API key (used for ICR, Secrets Manager, and cloud resources)", "mandatory": True},
        {"name": "service-functional-id-dev-ghe-pat", "description": "Service functional ID dev GitHub Enterprise personal access token (used for repository access)", "mandatory": True},
        {"name": "service-functional-id-prod-ghe-pat", "description": "Service functional ID production GitHub Enterprise personal access token (used for repository access)", "mandatory": True},
    ]
}

# Mandatory file definitions that should not be modified by teams
# Format: {group_name: [{path, can_be_empty, executable}]}
MANDATORY_FILES_TEMPLATE = {
    "CI": [
        {"path": "hack/ci/build.sh", "can_be_empty": False, "executable": True},
        {"path": "hack/ci/run-unit-tests.sh", "can_be_empty": False, "executable": True},
        {"path": "hack/ci/build-meta.yaml", "can_be_empty": False, "executable": False},
        {"path": "hack/ci/pipeline.yaml", "can_be_empty": False, "executable": False},
    ],
    "CD": [
        {"path": "hack/cd/pre-reqs.sh", "can_be_empty": False, "executable": True},
        {"path": "hack/cd/deploy.sh", "can_be_empty": False, "executable": True},
        {"path": "hack/cd/acceptance-tests.sh", "can_be_empty": False, "executable": True},
    ]
}

CONSISTENT_TEAM_FIELDS = [
    'service_fid_dev',
    'service_fid_prod',
    'service_fid_dev_github_username',
    'service_fid_prod_github_username',
    'psirt_id',
]

# Valid cicd_profile values
VALID_CICD_PROFILES = ['minimal', 'ci_only', 'ci_cd']

# Profile-aware mandatory secrets:
#   minimal:  only common group's 4 secrets enforced (no CI/CD pipeline)
#   ci_only:  CI + common enforced; CD skipped (no CD pipeline)
#   ci_cd:    full template enforced
MANDATORY_SECRETS_TEMPLATE_BY_PROFILE = {
    'minimal': {
        'common': MANDATORY_SECRETS_TEMPLATE['common'],
    },
    'ci_only': {
        'CI':     MANDATORY_SECRETS_TEMPLATE['CI'],
        'common': MANDATORY_SECRETS_TEMPLATE['common'],
    },
    'ci_cd':   MANDATORY_SECRETS_TEMPLATE,
}

# Profile-aware mandatory files:
#   minimal:  only hack/ci/build.sh enforced; CD group skipped
#   ci_only:  all CI files enforced; CD group skipped (no CD pipeline)
#   ci_cd:    full template enforced
MANDATORY_FILES_TEMPLATE_BY_PROFILE = {
    'minimal': {
        'CI': [{"path": "hack/ci/build.sh", "can_be_empty": False, "executable": True}],
    },
    'ci_only': {
        'CI': MANDATORY_FILES_TEMPLATE['CI'],
    },
    'ci_cd':   MANDATORY_FILES_TEMPLATE,
}

def _get_cicd_profile(data: Dict) -> Optional[str]:
    """Return the cicd_profile value, or None if not set."""
    return data.get('cicd_profile')

def print_error(msg: str):
    global errors
    print(f"{RED}[ERROR]{NC} {msg}")
    errors += 1

def print_warning(msg: str):
    global warnings
    print(f"{YELLOW}[WARNING]{NC} {msg}")
    warnings += 1

def print_success(msg: str):
    print(f"{GREEN}[SUCCESS]{NC} {msg}")

def print_info(msg: str):
    print(f"{BLUE}[INFO]{NC} {msg}")

def print_debug(msg: str):
    global debug_mode
    if debug_mode:
        print(f"{BLUE}[DEBUG]{NC} {msg}")

def _get_pr_changed_files() -> List[str]:
    """Return PR changed files when git context is available."""
    env_candidates = [
        'CHANGED_FILES',
        'PR_CHANGED_FILES',
        'GIT_CHANGED_FILES',
    ]

    for env_var in env_candidates:
        value = os.environ.get(env_var, '').strip()
        if value:
            files = [line.strip() for line in value.splitlines() if line.strip()]
            if files:
                print_debug(f"Using changed files from {env_var}: {files}")
                return files

    repo_root = Path(__file__).resolve().parents[7]
    diff_candidates = []
    pr_base_ref = os.environ.get('PR_BASE_REF', '').strip()
    pr_basebranch = os.environ.get('PR_BASEBRANCH', '').strip()

    if pr_base_ref:
        diff_candidates.append(pr_base_ref)
    if pr_basebranch:
        diff_candidates.extend([
            f"origin/{pr_basebranch}",
            pr_basebranch,
        ])

    seen = set()
    for candidate in diff_candidates:
        if not candidate or candidate in seen:
            continue
        seen.add(candidate)

        try:
            result = subprocess.run(
                ['git', 'diff', '--name-status', candidate, 'HEAD'],
                cwd=repo_root,
                capture_output=True,
                text=True,
                check=True,
            )
        except Exception as exc:
            print_debug(f"Unable to get changed files against '{candidate}': {exc}")
            continue

        files = [line.strip() for line in result.stdout.splitlines() if line.strip()]
        if files:
            print_debug(f"Using changed files from git diff against '{candidate}': {files}")
            return files

    print_warning("Could not determine changed files for this PR — template protection check skipped")
    return []


def _find_team_onboarding_files(yaml_file: str, data: Dict) -> List[Path]:
    """Return all <service>-onboarding.yaml files for the same team directory."""
    yaml_path = Path(yaml_file).resolve()
    team_name = data.get('team_name', '')
    expected_slug = team_name.lower().replace(' ', '-') if team_name else ''

    search_dirs = [yaml_path.parent]
    if expected_slug and yaml_path.parent.name != expected_slug and yaml_path.parent.parent.exists():
        candidate_dir = yaml_path.parent.parent / expected_slug
        if candidate_dir.is_dir():
            search_dirs.insert(0, candidate_dir)

    for directory in search_dirs:
        onboarding_files = sorted(
            path for path in directory.glob('*-onboarding.yaml')
            if path.is_file()
        )
        if onboarding_files:
            print_debug(f"Found team onboarding files in {directory}: {[str(path) for path in onboarding_files]}")
            return onboarding_files

    return []


def load_yaml(file_path: str) -> Dict:
    """Load YAML file"""
    try:
        with open(file_path, 'r') as f:
            return yaml.safe_load(f)
    except FileNotFoundError:
        print_error(f"YAML file not found: {file_path}")
        sys.exit(1)
    except yaml.YAMLError as e:
        print_error(f"Failed to parse YAML file: {e}")
        sys.exit(1)
    except Exception as e:
        print_error(f"Unexpected error loading YAML: {e}")
        sys.exit(1)

# Human-readable summary of what each profile validates and skips.
_PROFILE_VALIDATION_SCOPE = {
    'minimal': {
        'validated': [
            'team_name', 'service_name', 'cicd_profile',
            'service_fid_dev', 'service_fid_dev_github_username',
            'compliance_bucket', 'app_repo',
            'slack_member_ids', 'slack_channel',
            'secrets.common (4 mandatory)',
            'secrets.CI / secrets.CD (custom secrets only — mandatory=false enforced)',
            'mandatory_files.CI → hack/ci/build.sh only',
        ],
        'skipped': [
            'service_fid_prod / service_fid_prod_github_username (no production deployment)',
            'inventory_repo (no compliance inventory)',
            'incident_repo (no CD pipeline)',
            'psirt_id (no SAST scanning)',
            'servicenow_crn (ci_cd only)',
            'secrets.CI / secrets.CD mandatory secrets (none required for minimal)',
            'mandatory_files.CD (no CD pipeline)',
            'optional_files.mend (no SAST scanning)',
            'deployment_targets (no CI/CD environments)',
        ],
    },
    'ci_only': {
        'validated': [
            'team_name', 'service_name', 'cicd_profile',
            'service_fid_dev', 'service_fid_prod',
            'service_fid_dev_github_username', 'service_fid_prod_github_username',
            'compliance_bucket', 'app_repo', 'psirt_id',
            'incident_repo',
            'slack_member_ids', 'slack_channel',
            'secrets.CI (5 mandatory)', 'secrets.common (4 mandatory)',
            'mandatory_files.CI (all 4 files)',
            'optional_files.mend',
        ],
        'skipped': [
            'inventory_repo (no compliance inventory for ci_only)',
            'servicenow_crn (ci_cd only)',
            'secrets.CD mandatory secrets (no CD pipeline)',
            'mandatory_files.CD (no CD pipeline)',
            'deployment_targets.CI (no CI test environments for libraries/SDKs)',
            'deployment_targets.CD (no CD pipeline)',
        ],
    },
    'ci_cd': {
        'validated': [
            'team_name', 'service_name', 'cicd_profile',
            'service_fid_dev', 'service_fid_prod',
            'service_fid_dev_github_username', 'service_fid_prod_github_username',
            'compliance_bucket', 'app_repo', 'psirt_id',
            'inventory_repo',
            'incident_repo',
            'slack_member_ids', 'slack_channel',
            'servicenow_crn',
            'secrets.CI (5 mandatory)', 'secrets.CD (3 mandatory)', 'secrets.common (4 mandatory)',
            'mandatory_files.CI (all 4 files)', 'mandatory_files.CD (all 3 files)',
            'optional_files.mend',
            'deployment_targets.CI', 'deployment_targets.CD',
        ],
        'skipped': [],
    },
}


def print_validation_scope(profile: str):
    """Print a clear upfront summary of what will and won't be validated for the given profile."""
    scope = _PROFILE_VALIDATION_SCOPE.get(profile)
    if not scope:
        return

    print(f"{BLUE}{'─' * 50}{NC}")
    print(f"{BLUE}  Validation scope for cicd_profile: {profile}{NC}")
    print(f"{BLUE}{'─' * 50}{NC}")

    print(f"{GREEN}  Will validate:{NC}")
    for item in scope['validated']:
        print(f"    ✓  {item}")

    if scope['skipped']:
        print(f"{YELLOW}  Will skip (not required for '{profile}'):{NC}")
        for item in scope['skipped']:
            print(f"    –  {item}")

    print(f"{BLUE}{'─' * 50}{NC}")


def validate_cicd_profile(data: Dict):
    """Validate cicd_profile field and print the validation scope summary."""
    print_info("Validating cicd_profile...")
    profile = data.get('cicd_profile')

    if not profile:
        print_error(f"cicd_profile is required but not set. Allowed values: {' | '.join(VALID_CICD_PROFILES)}")
        return

    if profile not in VALID_CICD_PROFILES:
        print_error(f"cicd_profile '{profile}' is invalid. Allowed values: {' | '.join(VALID_CICD_PROFILES)}")
    else:
        print_success(f"cicd_profile is valid: {profile}")
        print()
        print_validation_scope(profile)


def validate_team_name(data: Dict):
    """Validate team name (case-insensitive)."""
    print_info("Validating team name...")
    team_name = data.get('team_name')

    if not team_name:
        print_error("Team name is missing or empty")
        return

    if team_name.lower() == "myteamname":
        print_error("Team name is still set to default value 'myteamname'. Please provide a valid team name.")
        return

    canonical = _VALID_TEAMS_LOWER.get(team_name.lower())
    if canonical is None:
        print_error(f"Invalid team name: '{team_name}'. Must be one of: {', '.join(VALID_TEAMS)}")
    else:
        if team_name != canonical:
            print_warning(f"Team name '{team_name}' accepted but canonical form is '{canonical}' — consider updating for consistency")
        print_success(f"Team name is valid: {team_name}")

def validate_service_name(data: Dict):
    """Validate service name"""
    print_info("Validating service name...")
    service_name = data.get('service_name')
    
    if not service_name:
        print_error("Service name is missing or empty")
        return
    
    if service_name == "myservicename":
        print_error("Service name is still set to default placeholder value 'myservicename'. Please provide a valid service name.")
        return
    
    # Check for common placeholder patterns
    placeholder_patterns = ['myservice', 'service_name', 'servicename', 'test', 'example']
    if any(pattern in service_name.lower() for pattern in placeholder_patterns):
        print_warning(f"Service name '{service_name}' may contain placeholder value. Please ensure it's a valid service name.")
    
    # Service name should be alphanumeric with hyphens/underscores
    if not re.match(r'^[a-zA-Z0-9_-]+$', service_name):
        print_error(f"Service name '{service_name}' contains invalid characters. Use only alphanumeric characters, hyphens, and underscores.")
    else:
        print_success(f"Service name is valid: {service_name}")

def validate_functional_ids(data: Dict):
    """Validate service functional IDs"""
    print_info("Validating service functional IDs...")
    profile = _get_cicd_profile(data)
    fid_dev = data.get('service_fid_dev')
    fid_prod = data.get('service_fid_prod')

    # Email pattern for validation
    email_pattern = r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'

    # Validate dev FID (required for all profiles)
    if not fid_dev:
        print_error("service_fid_dev is missing")
    elif fid_dev in ['my_fid@ibm.com', 'myfid@ibm.com']:
        print_error(f"service_fid_dev contains placeholder value: {fid_dev}")
    elif not re.match(email_pattern, fid_dev):
        print_error(f"service_fid_dev has invalid email format: {fid_dev}")
    else:
        print_success(f"service_fid_dev is valid: {fid_dev}")

    # Validate prod FID — not required for minimal (no production deployment)
    if profile == 'minimal':
        if fid_prod and fid_prod not in ['my_fid_prod@ibm.com', 'myfid_prod@ibm.com', 'my_fid@ibm.com']:
            print_success(f"service_fid_prod is provided (optional for minimal): {fid_prod}")
        else:
            print_info("service_fid_prod is not required for cicd_profile 'minimal' (no production deployment) — skipping")
    else:
        if not fid_prod:
            print_error("service_fid_prod is missing")
        elif fid_prod in ['my_fid_prod@ibm.com', 'myfid_prod@ibm.com', 'my_fid@ibm.com']:
            print_error(f"service_fid_prod contains placeholder value: {fid_prod}")
        elif not re.match(email_pattern, fid_prod):
            print_error(f"service_fid_prod has invalid email format: {fid_prod}")
        else:
            print_success(f"service_fid_prod is valid: {fid_prod}")

    # Check if dev and prod FIDs are the same (warning — only meaningful when both are required)
    if profile != 'minimal' and fid_dev and fid_prod and fid_dev == fid_prod:
        print_warning("service_fid_dev and service_fid_prod are the same. Consider using different FIDs for dev and production environments.")

def validate_inventory_repo(data: Dict):
    """Validate inventory repository.

    repo and branch are ALWAYS required regardless of create value.
    The pipeline uses the URL to derive the target org and repo name whether
    it is creating (fork) or just referencing an existing repo.
    Expected naming format: uuc-<team_slug>-<app_repo_name>-compliance-inventory

    Skipped for cicd_profile 'minimal' and 'ci_only' — inventory_repo is required for ci_cd only.
    """
    print_info("Validating inventory repository...")
    profile = _get_cicd_profile(data)
    if profile in ('minimal', 'ci_only'):
        print_info(f"cicd_profile is '{profile}' — inventory_repo is not required, skipping")
        return
    inventory_repo = data.get('inventory_repo', {})
    repo   = inventory_repo.get('repo')
    branch = inventory_repo.get('branch')
    create = inventory_repo.get('create', False)

    create_requested = str(create).lower() == 'true'
    print_info(f"inventory_repo.create: {create} — "
               f"{'pipeline will fork compliance-inventory template into this location' if create_requested else 'pipeline will use the existing repository at this location'}")

    # Placeholder check
    placeholder_patterns = ['myinventoryrepo', 'myteamname', 'myrepo', 'myorg']
    has_placeholder = repo and any(p in str(repo).lower() for p in placeholder_patterns)

    if not repo:
        print_error("inventory_repo.repo is missing")
        print_error("  repo is required regardless of create value — provide the full GitHub URL")
        print_error("  Format: https://github.ibm.com/<org>/uuc-<team_slug>-<app_repo_name>-compliance-inventory")
    elif has_placeholder:
        print_error(f"inventory_repo.repo contains a placeholder value: {repo}")
        print_error("  Replace placeholders (myinventoryrepo, myteamname, myrepo, myorg) with real values")
        print_error("  Format: https://github.ibm.com/<org>/uuc-<team_slug>-<app_repo_name>-compliance-inventory")
    else:
        print_success(f"inventory_repo.repo is provided: {repo}")

        # Validate GitHub URL structure: must resolve to github.ibm.com/<org>/<repo>
        url_parts = (repo.rstrip('/').removesuffix('.git')).split('/')
        if len(url_parts) < 2 or not url_parts[-2] or not url_parts[-1]:
            print_error(f"inventory_repo.repo URL structure is invalid: {repo}")
            print_error("  Expected format: https://github.ibm.com/<org>/<repo-name>")
        else:
            inventory_repo_name = url_parts[-1]
            inventory_org       = url_parts[-2]
            print_success(f"  Org: {inventory_org}  Repo: {inventory_repo_name}")

            # Validate naming convention: uuc-<team_slug>-<app_repo_name>-compliance-inventory
            team_name = data.get('team_name', '')
            app_repos = data.get('app_repo', [])

            if team_name and team_name != 'myteamname' and app_repos:
                app_repo_url = app_repos[0].get('repo', '')
                if app_repo_url and 'myorg' not in app_repo_url and 'myrepo' not in app_repo_url:
                    app_repo_name  = (app_repo_url.rstrip('/').removesuffix('.git')).split('/')[-1]
                    formatted_team = team_name.lower().replace(' ', '-')
                    expected       = f"uuc-{formatted_team}-{app_repo_name}-compliance-inventory"

                    if not (inventory_repo_name == expected or inventory_repo_name == f"{expected}.git"):
                        print_error("inventory_repo name format is incorrect")
                        print_error(f"  Expected: .../{expected}")
                        print_error(f"  Got:      .../{inventory_repo_name}")
                        print_info(f"  team_slug: {formatted_team},  app_repo_name: {app_repo_name}")
                    else:
                        print_success(f"inventory_repo naming format is correct: {expected}")

    if not branch:
        print_error("inventory_repo.branch is missing")
        print_error("  branch is required regardless of create value")
    else:
        print_success(f"inventory_repo.branch is provided: {branch}")


def validate_incident_repo(data: Dict):
    """Validate incident repository.

    repo and branch are ALWAYS required regardless of create value.
    The pipeline uses the URL to derive the target org and repo name whether
    it is creating a new repo or just referencing an existing one.

    Skipped for cicd_profile 'minimal' only — incident_repo is required for ci_only and ci_cd.
    """
    print_info("Validating incident repository...")
    profile = _get_cicd_profile(data)
    if profile == 'minimal':
        print_info("cicd_profile is 'minimal' — incident_repo is not required, skipping")
        return
    incident_repo = data.get('incident_repo', {})
    repo   = incident_repo.get('repo')
    branch = incident_repo.get('branch')
    create = incident_repo.get('create', False)

    create_requested = str(create).lower() == 'true'
    print_info(f"incident_repo.create: {create} — "
               f"{'pipeline will create a blank repo with README at this location' if create_requested else 'pipeline will use the existing repository at this location'}")

    # Placeholder check
    placeholder_patterns = ['myincidentrepo', 'myorg']
    has_placeholder = repo and any(p in str(repo).lower() for p in placeholder_patterns)

    if not repo:
        print_error("incident_repo.repo is missing")
        print_error("  repo is required regardless of create value — provide the full GitHub URL")
        print_error("  Format: https://github.ibm.com/<org>/<repo-name>")
    elif has_placeholder:
        print_error(f"incident_repo.repo contains a placeholder value: {repo}")
        print_error("  Replace placeholders (myincidentrepo, myorg) with real values")
        print_error("  Format: https://github.ibm.com/<org>/<repo-name>")
    else:
        print_success(f"incident_repo.repo is provided: {repo}")

        # Validate GitHub URL structure: must resolve to github.ibm.com/<org>/<repo>
        url_parts = (repo.rstrip('/').removesuffix('.git')).split('/')
        if len(url_parts) < 2 or not url_parts[-2] or not url_parts[-1]:
            print_error(f"incident_repo.repo URL structure is invalid: {repo}")
            print_error("  Expected format: https://github.ibm.com/<org>/<repo-name>")
        else:
            print_success(f"  Org: {url_parts[-2]}  Repo: {url_parts[-1]}")

    if not branch:
        print_error("incident_repo.branch is missing")
        print_error("  branch is required regardless of create value")
    else:
        print_success(f"incident_repo.branch is provided: {branch}")

def validate_compliance_bucket(data: Dict):
    """Validate compliance bucket configuration"""
    print_info("Validating compliance bucket configuration...")
    compliance_bucket = data.get('compliance_bucket', {})
    use_existing = compliance_bucket.get('use_existing', False)
    endpoint = compliance_bucket.get('endpoint')
    bucket_name = compliance_bucket.get('name')
    
    if use_existing:
        print_info("Using existing compliance bucket - validating custom endpoint and bucket name...")
        
        # When use_existing is true, custom endpoint and bucket name are required
        if not endpoint:
            print_error("Compliance bucket endpoint is required when use_existing is true")
        elif 's3.eu-gb.cloud-object-storage.appdomain.cloud' in str(endpoint):
            print_error("Compliance bucket endpoint contains default placeholder value. When use_existing is true, you must provide your custom endpoint.")
        else:
            print_success(f"Compliance bucket custom endpoint is provided: {endpoint}")
        
        if not bucket_name:
            print_error("Compliance bucket name is required when use_existing is true")
        elif bucket_name == 'my_bucket':
            print_error("Compliance bucket name contains default placeholder value. When use_existing is true, you must provide your custom bucket name.")
        else:
            print_success(f"Compliance bucket custom name is provided: {bucket_name}")
        
        print_warning("Ensure 'onepipelineci@ibm.com' FID has write access to your custom compliance bucket")
    else:
        print_success("Using CICD-managed compliance bucket (endpoint and name will be automatically set as uuc-<team-name-with-spaces-replaced-by-hyphens>-ci-storage)")

def validate_app_repo(data: Dict):
    """Validate application repositories"""
    print_info("Validating application repositories...")
    app_repos = data.get('app_repo', [])
    
    if not app_repos:
        print_error("No application repositories defined")
        return
    
    for i, app_repo in enumerate(app_repos, 1):
        repo = app_repo.get('repo')
        branch = app_repo.get('branch')
        
        if not repo or 'myorg' in str(repo) or 'myrepo' in str(repo):
            print_error(f"App repository #{i} is missing or contains default placeholder (myorg/myrepo)")
        else:
            print_success(f"App repository #{i} is valid: {repo}")
        
        if not branch:
            print_error(f"App repository #{i} branch is missing")
        else:
            print_success(f"App repository #{i} branch is valid: {branch}")

def validate_psirt_id(data: Dict):
    """Validate PSIRT ID.

    Skipped for cicd_profile 'minimal' — no SAST scanning.
    """
    print_info("Validating PSIRT ID...")
    profile = _get_cicd_profile(data)
    if profile == 'minimal':
        print_info("cicd_profile is 'minimal' — psirt_id is not required (no SAST scanning), skipping")
        return
    psirt_id = data.get('psirt_id')
    
    if not psirt_id:
        print_error("PSIRT ID is missing")
        return
    
    # Check for placeholder values
    placeholder_patterns = ['PSIRT_PRD000XXXX', 'PSIRT_PRD0000000', 'PSIRT_PRDXXXXXXX']
    if psirt_id in placeholder_patterns:
        print_error(f"PSIRT ID is still set to placeholder value: {psirt_id}")
        return
    
    # Check if it contains only zeros (like PSIRT_PRD0000000)
    if re.match(r'^PSIRT_PRD0+$', psirt_id):
        print_error(f"PSIRT ID contains only zeros: {psirt_id}. Please provide a valid PSIRT ID.")
        return
    
    # Validate format: PSIRT_PRD followed by exactly 7 digits
    if not re.match(r'^PSIRT_PRD\d{7}$', psirt_id):
        print_error(f"PSIRT ID format is invalid. Expected format: PSIRT_PRD0000000 (7 digits), got: {psirt_id}")
    else:
        print_success(f"PSIRT ID is valid: {psirt_id}")

def validate_servicenow_crn(data: Dict):
    """Validate servicenow_crn field.

    Required for cicd_profile 'ci_cd' only — skipped for 'minimal' and 'ci_only'.
    This field can differ per service within the same team and is therefore not
    enforced as a consistent team field.
    """
    print_info("Validating ServiceNow CRN...")
    profile = _get_cicd_profile(data)
    if profile in ('minimal', 'ci_only'):
        print_info(f"cicd_profile is '{profile}' — servicenow_crn is not required, skipping")
        return
    crn = data.get('servicenow_crn')

    if not crn:
        print_warning("servicenow_crn is not provided (optional)")
        return

    if str(crn).strip() == '<your_servicenow_crn>':
        print_warning(
            "servicenow_crn is still set to the placeholder value "
            "'<your_servicenow_crn>'. Consider replacing it with your actual ServiceNow CRN."
        )
        return

    print_success(f"servicenow_crn is provided: {crn}")


def validate_ibm_cloud_accounts(data: Dict):
    """Validate IBM Cloud accounts (optional)"""
    print_info("Validating IBM Cloud accounts (optional)...")
    dev_account = data.get('ibm_cloud_account_dev')
    prod_account = data.get('ibm_cloud_account_prod')
    
    if dev_account and dev_account != 'my_dev_account':
        print_success(f"IBM Cloud dev account is provided: {dev_account}")
    else:
        print_warning("IBM Cloud dev account is not provided (optional)")
    
    if prod_account and prod_account != 'my_prod_account':
        print_success(f"IBM Cloud prod account is provided: {prod_account}")
    else:
        print_warning("IBM Cloud prod account is not provided (optional)")

def validate_slack_config(data: Dict):
    """Validate Slack configuration"""
    print_info("Validating Slack configuration...")
    slack_member_ids = data.get('slack_member_ids', [])
    
    if not slack_member_ids:
        print_error("Slack member IDs are mandatory but not provided")
        return
    
    example_ids = ['U01234ABCDE', 'U56789FGHIJ']
    has_example = any(member_id in example_ids for member_id in slack_member_ids)
    
    if has_example:
        print_error("Slack member IDs contain example values. Please replace with actual Slack member IDs.")
    else:
        print_success(f"Slack member IDs are provided ({len(slack_member_ids)} members)")
    
    slack_channel = data.get('slack_channel')
    if slack_channel:
        # Check for placeholder values mentioned in comments
        if 'my-team-alerts' in str(slack_channel) or 'your-channel' in str(slack_channel):
            print_error(f"Slack channel contains placeholder value: {slack_channel}. Please provide your team's actual Slack channel or remove to use default.")
        else:
            print_success(f"Slack channel is provided: {slack_channel}")
    else:
        print_info("Slack channel not provided (optional) - will use default channel")

def validate_secrets(data: Dict):
    """Validate secrets configuration - ensures mandatory secrets are not modified or removed.

    Profile-aware behaviour:
      - minimal:  Only common group's 4 secrets are mandatory. CI and CD groups may be
                  present (for custom secrets) but have no platform-mandatory secrets.
      - ci_only:  CI (5) + common (4) mandatory secrets enforced. CD group has no
                  platform-mandatory secrets (no CD pipeline).
      - ci_cd:    Full MANDATORY_SECRETS_TEMPLATE enforcement (CI + CD + common).
    """
    print_info("Validating secrets configuration...")
    profile = _get_cicd_profile(data)
    effective_template = MANDATORY_SECRETS_TEMPLATE_BY_PROFILE.get(profile, MANDATORY_SECRETS_TEMPLATE)

    secret_groups = data.get('secrets', [])

    if not secret_groups:
        print_error("No secret groups defined")
        return

    for group in secret_groups:
        group_name = group.get('name')
        items = group.get('items', [])

        print_info(f"Checking secret group: {group_name} ({len(items)} items)")

        # Get the mandatory secrets template for this group under the active profile
        template_secrets = effective_template.get(group_name, [])

        if template_secrets:
            # Count mandatory secrets in the current configuration
            mandatory_count = sum(1 for item in items if item.get('mandatory') == True)
            expected_mandatory_count = len(template_secrets)

            # Strict count validation - detect removals
            if mandatory_count < expected_mandatory_count:
                print_error(f"Secret group '{group_name}' has {mandatory_count} mandatory secrets but expected {expected_mandatory_count}. Mandatory secrets may have been removed! (DO NOT REMOVE)")
            elif mandatory_count > expected_mandatory_count:
                print_error(f"Secret group '{group_name}' has {mandatory_count} mandatory secrets but expected {expected_mandatory_count}. Extra mandatory secrets detected (custom secrets must have mandatory=false)")
            else:
                print_success(f"Secret group '{group_name}' has correct number of mandatory secrets: {mandatory_count}")
        else:
            # No mandatory secrets for this group under the active profile
            # (e.g. CI/CD groups for minimal) — warn if team accidentally set mandatory=true
            rogue = [item.get('name') for item in items if item.get('mandatory') == True]
            if rogue:
                print_error(
                    f"Secret group '{group_name}' has no platform-mandatory secrets for "
                    f"cicd_profile '{profile}', but found mandatory=true on: {rogue}. "
                    f"Custom secrets must have mandatory=false."
                )
        
        # Build a flat set of all mandatory secret names for collision detection.
        # Also include the mend base patterns so that a custom secret whose name
        # contains a mend keyword is caught the same way as an exact-name match.
        mandatory_secret_names = {t['name'] for t in template_secrets}

        # Track which mandatory secrets we've found (use full template name as key)
        found_mandatory_secrets = set()
        
        for item in items:
            secret_name = item.get('name')
            secret_desc = item.get('description')
            secret_mandatory = item.get('mandatory')
            team_name = data.get('team_name', '')
            team_slug = team_name.lower().replace(' ', '-') if team_name else ''
            secret_group_prefix = f"sg-uuc-{team_slug}-" if team_slug else ""
            
            # Check if this matches a mandatory secret template
            is_mandatory_secret = False
            matched_template = None
            
            for template in template_secrets:
                template_name = template['name']
                # For mend secrets, check if the base pattern matches (e.g., "mend-org-token" in "PSIRT_PRD1234567-mend-org-token")
                if 'mend' in template_name:
                    # Extract the mend secret type (e.g., "mend-org-token", "mend-user-key", "mend-product-token")
                    if template_name in str(secret_name):
                        is_mandatory_secret = True
                        matched_template = template
                        found_mandatory_secrets.add(template_name)
                        break
                else:
                    # For non-mend secrets, exact name match
                    if template_name == secret_name:
                        is_mandatory_secret = True
                        matched_template = template
                        found_mandatory_secrets.add(template_name)
                        break
            
            if is_mandatory_secret and matched_template:
                # Validate that mandatory secret properties haven't been modified
                template_desc = matched_template['description']
                template_mandatory = matched_template['mandatory']
                
                # Check if description was modified (allow PSIRT ID substitution)
                if 'PSIRT_PRD' not in secret_desc and template_desc not in secret_desc:
                    # For mend secrets, check if base description matches
                    if 'Mend SAST' in template_desc:
                        if 'Mend SAST' not in secret_desc:
                            print_error(f"Mandatory secret '{secret_name}' description was modified. Expected to contain: '{template_desc}'")
                    else:
                        print_error(f"Mandatory secret '{secret_name}' description was modified. Expected: '{template_desc}'")
                
                # Check if mandatory flag was modified
                if secret_mandatory != template_mandatory:
                    print_error(f"Mandatory secret '{secret_name}' has mandatory flag set to '{secret_mandatory}' instead of '{template_mandatory}' (DO NOT MODIFY)")
            else:
                # This is a custom secret
                if '<your_secret_name>' in str(secret_name) or '<your_secret_description>' in str(secret_desc):
                    print_warning("Custom secret contains placeholder values - ensure to replace before onboarding")

                # Prevent custom secrets from using the same name as a mandatory secret.
                # A user must not shadow a platform-managed secret by declaring it with
                # mandatory=false — the name itself is reserved.
                if isinstance(secret_name, str):
                    for mandatory_name in mandatory_secret_names:
                        if ('mend' in mandatory_name and mandatory_name in secret_name) or mandatory_name == secret_name:
                            print_error(
                                f"[RESERVED] Secret name '{mandatory_name}' is reserved for a "
                                f"platform-managed mandatory secret and cannot be used for a custom secret. "
                                f"Remove '{secret_name}' or rename it to something that does not conflict "
                                f"with a mandatory secret name."
                            )
                            break

                if secret_mandatory == True:
                    print_error(f"Custom secret '{secret_name}' cannot have mandatory flag set to 'true'")

                if secret_group_prefix and isinstance(secret_name, str) and secret_name.startswith(secret_group_prefix):
                    print_error(
                        f"Custom secret '{secret_name}' must not include the secret group prefix '{secret_group_prefix}'. "
                        f"Provide only the raw secret name because the prefix is added automatically during provisioning."
                    )
            
            # Validate required fields
            if not secret_name:
                print_error(f"Secret in group '{group_name}' is missing name")
            
            if not secret_desc:
                print_error(f"Secret '{secret_name}' is missing description")
            
            if secret_mandatory is None:
                print_error(f"Secret '{secret_name}' is missing mandatory flag")
        
        # Check if any mandatory secrets are missing
        if template_secrets:
            # Get all template secret names
            all_template_names = {template['name'] for template in template_secrets}
            missing_secrets = all_template_names - found_mandatory_secrets
            
            if missing_secrets:
                for missing_name in missing_secrets:
                    # Find the template to get the description
                    for template in template_secrets:
                        if template['name'] == missing_name:
                            print_error(f"Mandatory secret '{missing_name}' (description: '{template['description']}') is missing from group '{group_name}' (DO NOT REMOVE platform-managed secrets)")
                            break
    
    print_success("Secrets validation completed")

def validate_mandatory_files(data: Dict):
    """Validate mandatory files configuration - ensures file properties are not modified.

    Profile-aware behaviour:
      - minimal:  Only hack/ci/build.sh in the CI group is enforced. The CD group is
                  skipped entirely (no CD pipeline). Any other CI files present are
                  validated for structural correctness but not enforced as required.
      - ci_only:  All 4 CI files enforced. CD group skipped entirely (no CD pipeline).
      - ci_cd:    Full MANDATORY_FILES_TEMPLATE enforcement (CI + CD).
    """
    print_info("Validating mandatory files configuration...")
    profile = _get_cicd_profile(data)
    effective_template = MANDATORY_FILES_TEMPLATE_BY_PROFILE.get(profile, MANDATORY_FILES_TEMPLATE)

    file_groups = data.get('mandatory_files', [])

    if not file_groups:
        print_error("No mandatory file groups defined")
        return

    for group in file_groups:
        group_name = group.get('name')
        repo = group.get('repo')
        branch = group.get('branch')
        files = group.get('files', [])

        # For minimal and ci_only profiles, skip the CD group entirely (no CD pipeline)
        if profile in ('minimal', 'ci_only') and group_name == 'CD':
            print_info(f"cicd_profile is '{profile}' — mandatory_files group 'CD' is not required (no CD pipeline), skipping")
            continue

        print_info(f"Checking mandatory file group: {group_name}")

        # Teams should only provide repo and branch, not modify file properties
        if not repo or 'myrepo' in str(repo) or 'myorg' in str(repo):
            print_error(f"Mandatory files group '{group_name}' has invalid or placeholder repo (myorg/myrepo)")
        else:
            print_success(f"Mandatory files group '{group_name}' repo is valid: {repo}")

        if not branch:
            print_error(f"Mandatory files group '{group_name}' is missing branch")
        else:
            print_success(f"Mandatory files group '{group_name}' branch is valid: {branch}")

        # Get the effective template for this group under the active profile
        template_files = effective_template.get(group_name, [])

        if not files:
            print_error(f"Mandatory files group '{group_name}' has no files defined")
        else:
            # For minimal CI group: only the required file (build.sh) must be present;
            # extra files are allowed (structural validation applied) but not enforced.
            required_paths = {tf['path'] for tf in template_files}
            file_paths = {f.get('path') for f in files if f.get('path')}

            # Check required files are present
            for missing_path in required_paths - file_paths:
                print_error(f"Mandatory file '{missing_path}' is missing from group '{group_name}' (DO NOT REMOVE platform-managed files)")

            if profile == 'minimal' and group_name == 'CI':
                print_info(f"cicd_profile is 'minimal' — only 'hack/ci/build.sh' is enforced in CI group; extra files are allowed")
            else:
                # For ci_only / ci_cd: strict count check
                if len(template_files) > 0 and len(files) != len(template_files):
                    print_error(f"Mandatory files group '{group_name}' has {len(files)} files but expected {len(template_files)} (DO NOT MODIFY file list)")
                else:
                    print_success(f"Mandatory files group '{group_name}' has {len(files)} files defined")

            # Create a map of all template files by path for property validation
            full_template_map = {tf['path']: tf for tf in MANDATORY_FILES_TEMPLATE.get(group_name, [])}

            for file_item in files:
                file_path = file_item.get('path')
                can_be_empty = file_item.get('can_be_empty')
                executable = file_item.get('executable')

                if not file_path:
                    print_error(f"File in group '{group_name}' is missing path")
                    continue

                # Check if this file exists in the full platform template
                if file_path in full_template_map:
                    template_file = full_template_map[file_path]

                    # Validate that executable property hasn't been modified
                    # Note: can_be_empty can be changed by teams if required
                    if executable != template_file['executable']:
                        print_error(f"File '{file_path}' in group '{group_name}' has executable={executable} but expected {template_file['executable']} (DO NOT MODIFY)")

                    # Teams may change can_be_empty, but highlight false -> true explicitly
                    if can_be_empty != template_file['can_be_empty']:
                        if template_file['can_be_empty'] is False and can_be_empty is True:
                            print_warning(f"File '{file_path}' in group '{group_name}' changes can_be_empty from default false to true")
                        else:
                            print_warning(f"File '{file_path}' in group '{group_name}' has can_be_empty={can_be_empty} (template default: {template_file['can_be_empty']})")
                else:
                    # File not in any platform template — teams shouldn't add files to mandatory section
                    if len(full_template_map) > 0:
                        print_error(f"File '{file_path}' in group '{group_name}' is not a platform-managed file (DO NOT ADD custom files to mandatory_files)")

                # Validate required fields are present
                if can_be_empty is None:
                    print_error(f"File '{file_path}' in group '{group_name}' is missing can_be_empty property")

                if executable is None:
                    print_error(f"File '{file_path}' in group '{group_name}' is missing executable property")

def validate_deployment_targets(data: Dict):
    """Validate deployment targets.

    Skipped entirely for cicd_profile 'minimal' — no CI test environments, no CD deployments.
    For cicd_profile 'ci_only' — deployment_targets.CI is skipped (no CI test environments
    for libraries/SDKs); deployment_targets.CD is skipped (no CD pipeline).
    """
    print_info("Validating deployment targets...")
    profile = _get_cicd_profile(data)
    if profile == 'minimal':
        print_info("cicd_profile is 'minimal' — deployment_targets is not required, skipping")
        return
    if profile == 'ci_only':
        print_info("cicd_profile is 'ci_only' — deployment_targets is not required (no CI test environments or CD pipeline), skipping")
        return
    deployment_targets = data.get('deployment_targets', {})
    
    # Placeholder patterns for detection
    ci_zone_placeholders = ['zone1', 'zone2', 'zone3', 'myzone', 'env_code']
    cd_override_placeholders = ['myspecialzone', 'myspecialzone1', 'myspecialzone2', 'myspecialzone3',
                                 'myspecialregion', 'myspecialregion1', 'myspecialregion2', 'myspecialregion3',
                                 'anotherzone', 'thirdzone', 'env_code']
    
    # Check CI targets - now organized by datacenter types (vpc_ng mandatory, ngdc optional)
    ci_targets = deployment_targets.get('CI', {})
    if not ci_targets:
        print_error("No CI deployment targets defined")
    else:
        # CI targets should be a dict with datacenter types
        if not isinstance(ci_targets, dict):
            print_error("CI deployment targets should be organized by datacenter types (vpc_ng, ngdc)")
        else:
            # vpc_ng is mandatory, ngdc is optional - ONLY these two are allowed
            mandatory_types = ['vpc_ng']
            optional_types = ['ngdc']
            allowed_types = mandatory_types + optional_types
            found_types = []
            
            # First, check for any custom/unexpected datacenter types (strict validation)
            for key in ci_targets.keys():
                if key not in allowed_types:
                    print_error(f"Invalid datacenter type '{key}' in CI deployment targets. Only 'vpc_ng' and 'ngdc' are allowed.")
            
            # Check mandatory datacenter types
            for dc_type in mandatory_types:
                dc_targets = ci_targets.get(dc_type, [])
                if dc_targets:
                    found_types.append(dc_type)
                    print_success(f"CI deployment targets for '{dc_type}' defined ({len(dc_targets)} zone(s))")
                    
                    for i, target in enumerate(dc_targets, 1):
                        target_name = target.get('name')
                        default_size = target.get('default_size')
                        
                        if not target_name:
                            print_error(f"CI {dc_type} target #{i} is missing name")
                        else:
                            # Check for placeholder zone names
                            if target_name.lower() in ci_zone_placeholders:
                                print_warning(f"CI {dc_type} target '{target_name}' appears to be a placeholder value. Update with actual zone name if details are available.")
                        
                        if not default_size:
                            print_error(f"CI {dc_type} target '{target_name}' is missing default_size")
                        
                        # Check if override_size exists (it shouldn't for CI targets)
                        if 'override_size' in target:
                            print_warning(f"CI {dc_type} target '{target_name}' has override_size defined. This is not required for CI targets and will be ignored.")
                else:
                    print_error(f"Mandatory datacenter type '{dc_type}' is missing in CI deployment targets")
            
            # Check optional datacenter types
            for dc_type in optional_types:
                dc_targets = ci_targets.get(dc_type, [])
                if dc_targets:
                    found_types.append(dc_type)
                    print_success(f"CI deployment targets for '{dc_type}' defined ({len(dc_targets)} zone(s)) - optional")
                    
                    for i, target in enumerate(dc_targets, 1):
                        target_name = target.get('name')
                        default_size = target.get('default_size')
                        
                        if not target_name:
                            print_error(f"CI {dc_type} target #{i} is missing name")
                        else:
                            # Check for placeholder zone names
                            if target_name.lower() in ci_zone_placeholders:
                                print_warning(f"CI {dc_type} target '{target_name}' appears to be a placeholder value. Update with actual zone name if details are available.")
                        
                        if not default_size:
                            print_error(f"CI {dc_type} target '{target_name}' is missing default_size")
                        
                        # Check if override_size exists (it shouldn't for CI targets)
                        if 'override_size' in target:
                            print_warning(f"CI {dc_type} target '{target_name}' has override_size defined. This is not required for CI targets and will be ignored.")
                else:
                    print_info(f"Optional datacenter type '{dc_type}' is not defined in CI deployment targets (optional)")
    
    # Check CD targets - ONLY integration, staging, and production are allowed
    cd_targets = deployment_targets.get('CD', {})
    allowed_environments = ['integration', 'staging', 'production']
    
    if not cd_targets:
        print_error("No CD deployment targets defined")
    else:
        # First, check for any custom/unexpected environments (strict validation)
        for env in cd_targets.keys():
            if env not in allowed_environments:
                print_error(f"Invalid environment '{env}' in CD deployment targets. Only 'integration', 'staging', and 'production' are allowed.")
        
        # Validate that all required environments are present (cannot be removed)
        for env in allowed_environments:
            if env not in cd_targets:
                print_error(f"CD {env} environment is missing from deployment_targets. All environments (integration, staging, production) must be present. You can keep placeholder data if you don't have details yet.")
        
        # Now validate the allowed environments
        for env in allowed_environments:
            env_config = cd_targets.get(env, {})
            
            # Skip if environment was removed (already reported as error above)
            if not env_config:
                continue
            
            targets = env_config.get('targets')
            target_type = env_config.get('type')
            default_size = env_config.get('default_size')
            override_size = env_config.get('override_size', [])
            exclude = env_config.get('exclude', []) or []

            # targets validation:
            #   - omitted / None  → warn, defaults to "all" at provisioning time
            #   - empty list []   → warn, nothing will be provisioned
            #   - "all"           → valid
            #   - non-empty list  → valid (specific region names)
            if targets is None:
                print_warning(f"CD {env} environment has no 'targets' specified — defaults to 'all' regions at provisioning time. Set targets: all explicitly or provide a list of region names.")
            elif isinstance(targets, list) and len(targets) == 0:
                print_warning(f"CD {env} environment has an empty targets list — no secrets will be provisioned for this environment. Set targets: all or provide at least one region name.")
            elif isinstance(targets, list):
                print_success(f"CD {env} environment targets: {len(targets)} specific region(s) — {targets}")
            elif targets == 'all':
                print_success(f"CD {env} environment targets: all")
            else:
                print_warning(f"CD {env} environment targets value '{targets}' is not 'all' or a list — will be treated as a single region name at provisioning time.")

            if not target_type:
                print_error(f"CD {env} environment is missing type")
            else:
                if target_type not in ['zonal', 'regional']:
                    print_error(f"CD {env} environment has invalid type: {target_type} (must be 'zonal' or 'regional')")
                else:
                    print_success(f"CD {env} environment type: {target_type}")

            if not default_size:
                print_error(f"CD {env} environment is missing default_size")
            else:
                print_success(f"CD {env} environment default_size: {default_size}")

            # Check exclude for placeholder values
            for excl in exclude:
                if str(excl).lower() in cd_override_placeholders or str(excl).lower() in ['region1', 'region2', 'region3']:
                    print_warning(f"CD {env} environment exclude entry '{excl}' appears to be a placeholder value. Update with actual region name or zone Universal Name.")

            # Check override_size for placeholder values
            if override_size:
                for override in override_size:
                    override_target = override.get('target')
                    if override_target and override_target.lower() in cd_override_placeholders:
                        print_warning(f"CD {env} environment override_size target '{override_target}' appears to be a placeholder value. Update with actual zone/region name if details are available.")

def validate_optional_files(data: Dict):
    """Validate optional files configuration.

    For cicd_profile 'minimal': the 'mend' group is skipped (no SAST scanning).
    """
    print_info("Validating optional files configuration...")
    profile = _get_cicd_profile(data)
    file_groups = data.get('optional_files', [])

    if not file_groups:
        print_info("No optional file groups defined (optional)")
        return

    print_info(f"Found {len(file_groups)} optional file group(s)")

    for group in file_groups:
        group_name = group.get('name')
        # mend SAST suppression file is irrelevant without a SAST scan
        if profile == 'minimal' and group_name == 'mend':
            print_info("cicd_profile is 'minimal' — optional_files group 'mend' is not applicable (no SAST scanning), skipping")
            continue
        repo = group.get('repo')
        branch = group.get('branch')
        files = group.get('files', [])
        
        print_info(f"Checking optional file group: {group_name}")
        
        # Check for placeholder values in repo
        if not repo:
            print_error(f"Optional files group '{group_name}' is missing repo")
        elif 'myrepo' in str(repo) or 'myorg' in str(repo) or 'my_repo' in str(repo):
            print_error(f"Optional files group '{group_name}' has placeholder repo value (myorg/myrepo/my_repo)")
        else:
            print_success(f"Optional files group '{group_name}' repo is valid: {repo}")
        
        if not branch or branch == 'default':
            print_warning(f"Optional files group '{group_name}' has missing or placeholder branch value")
        else:
            print_success(f"Optional files group '{group_name}' branch is valid: {branch}")
        
        if not files:
            print_warning(f"Optional files group '{group_name}' has no files defined")
        else:
            print_success(f"Optional files group '{group_name}' has {len(files)} file(s) defined")
            
            for file_item in files:
                file_path = file_item.get('path')
                can_be_empty = file_item.get('can_be_empty')
                executable = file_item.get('executable')
                
                if not file_path:
                    print_error(f"File in optional group '{group_name}' is missing path")
                
                if can_be_empty is None:
                    print_error(f"File '{file_path}' in optional group '{group_name}' is missing can_be_empty property")
                
                if executable is None:
                    print_error(f"File '{file_path}' in optional group '{group_name}' is missing executable property")

def validate_external_services(data: Dict):
    """Validate external services"""
    print_info("Validating external services...")
    external_services = data.get('external_services', [])
    
    if not external_services:
        print_info("No external services defined (optional)")
        return
    
    print_info(f"Found {len(external_services)} external service(s)")
    
    for i, service in enumerate(external_services, 1):
        service_name = service.get('name')
        endpoint = service.get('endpoint')
        service_type = service.get('type')
        
        if not service_name:
            print_error(f"External service #{i} is missing name")
        else:
            if service_name in ['event_stream', 'something_else']:
                print_warning(f"External service '{service_name}' appears to be a placeholder - ensure to update")
        
        if not endpoint or '<url' in str(endpoint):
            print_error(f"External service '{service_name}' has missing or placeholder endpoint")
        else:
            print_success(f"External service '{service_name}' endpoint is provided")
        
        if not service_type:
            print_error(f"External service '{service_name}' is missing type")
        else:
            if '|' in str(service_type):
                print_error(f"External service '{service_name}' type contains placeholder: {service_type}")
            elif service_type not in ['zonal', 'regional', 'global']:
                print_error(f"External service '{service_name}' has invalid type: {service_type} (must be 'zonal', 'regional', or 'global')")
            else:
                print_success(f"External service '{service_name}' type: {service_type}")

def validate_repo_consistency(data: Dict):
    """Validate that repo and branch are consistent across app_repo, mandatory_files, and optional_files"""
    print_info("Validating repository consistency across app_repo, mandatory_files, and optional_files...")
    
    # Get app_repo details (use first one as reference)
    app_repos = data.get('app_repo', [])
    if not app_repos:
        print_warning("No app_repo defined, skipping consistency check")
        return
    
    reference_repo = app_repos[0].get('repo')
    reference_branch = app_repos[0].get('branch')
    
    if not reference_repo or not reference_branch:
        print_warning("App repo or branch is missing, skipping consistency check")
        return
    
    print_info(f"Reference repo from app_repo: {reference_repo} (branch: {reference_branch})")
    
    # Check mandatory_files
    mandatory_files = data.get('mandatory_files', [])
    for group in mandatory_files:
        group_name = group.get('name')
        repo = group.get('repo')
        branch = group.get('branch')
        
        if repo and repo != reference_repo:
            print_error(f"Mandatory files group '{group_name}' repo '{repo}' does not match app_repo '{reference_repo}'")
        
        if branch and branch != reference_branch:
            print_error(f"Mandatory files group '{group_name}' branch '{branch}' does not match app_repo branch '{reference_branch}'")
    
    # Check optional_files
    optional_files = data.get('optional_files', [])
    for group in optional_files:
        group_name = group.get('name')
        repo = group.get('repo')
        branch = group.get('branch')
        
        if repo and repo != reference_repo:
            print_error(f"Optional files group '{group_name}' repo '{repo}' does not match app_repo '{reference_repo}'")
        
        if branch and branch != reference_branch:
            print_error(f"Optional files group '{group_name}' branch '{branch}' does not match app_repo branch '{reference_branch}'")
    
    print_success("Repository consistency validation completed")

# Platform-managed reference template filenames — must never be modified or deleted by service teams
_REFERENCE_TEMPLATES = frozenset({
    'onboarding-minimal.yaml',
    'onboarding-minimal.yml',
    'onboarding-ci_only.yaml',
    'onboarding-ci_only.yml',
    'onboarding-ci_cd.yaml',
    'onboarding-ci_cd.yml',
    # Legacy bare template — kept for safety in case old branches still carry it
    'onboarding.yaml',
    'onboarding.yml',
})


def validate_filename(yaml_file: str, data: Dict):
    """Validate filename rules for team onboarding files."""
    print_info("Validating filename format...")

    filename = os.path.basename(yaml_file)

    if filename in _REFERENCE_TEMPLATES:
        changed_files = _get_pr_changed_files()
        if changed_files:
            changed_entries = [Path(line.split('\t', 1)[-1]).name for line in changed_files]
            if filename in changed_entries:
                pr_labels = os.environ.get('PR_LABELS', '')
                label_names = {label.strip() for label in re.split(r'[,\n]', pr_labels) if label.strip()}
                if 'uuc-devops' in label_names:
                    print_warning(f"File '{filename}' is part of this PR, but allowed because PR label 'uuc-devops' is present")
                else:
                    print_error(f"File '{filename}' must not be changed by service teams")
                    print_error(f"  This file is a platform-managed reference template and must not be part of a team PR")
                    print_info("  If this is a DevOps change, add the PR label 'uuc-devops'")
                    return

            deleted_entries = {
                Path(line.split('\t', 1)[-1]).name
                for line in changed_files
                if line.startswith('D\t')
            }
            if filename in deleted_entries:
                print_error(f"Deleting '{filename}' is not allowed")
                print_error(f"  This file is a platform-managed reference template and must remain in the repository")
                print_info("  If this is a DevOps change, restore the file and use the 'uuc-devops' label only for allowed modifications")
                return

        print_success(f"Reference template filename '{filename}' is acceptable for non-team-managed changes")
        return

    service_name = data.get('service_name')

    if not service_name:
        print_warning("Cannot validate filename format: service_name is missing from configuration")
        return

    if service_name == 'myservicename':
        print_warning("Cannot validate filename format: service_name is still set to placeholder value")
        return

    expected_filename = f"{service_name}-onboarding.yaml"

    if filename != expected_filename:
        print_error(f"Filename does not follow the required format")
        print_error(f"  Expected: {expected_filename}")
        print_error(f"  Got: {filename}")
        print_info(f"  Filename must be in the format: <serviceName>-onboarding.yaml")
        print_info(f"  Where serviceName matches the 'service_name' field in the configuration")
    else:
        print_success(f"Filename format is correct: {filename}")


def validate_team_onboarding_consistency(yaml_file: str, data: Dict):
    """Validate common team values are consistent across all team onboarding files."""
    print_info("Validating cross-service onboarding consistency...")

    onboarding_files = _find_team_onboarding_files(yaml_file, data)
    if len(onboarding_files) <= 1:
        print_info("Only one team onboarding file found — cross-service consistency check skipped")
        return

    reference_values = {field: data.get(field) for field in CONSISTENT_TEAM_FIELDS}

    for other_file in onboarding_files:
        if other_file.resolve() == Path(yaml_file).resolve():
            continue

        other_data = load_yaml(str(other_file))
        for field in CONSISTENT_TEAM_FIELDS:
            if other_data.get(field) != reference_values.get(field):
                print_error(
                    f"Field '{field}' must match across all team onboarding files. "
                    f"Current file has '{reference_values.get(field)}' but '{other_file.name}' has '{other_data.get(field)}'"
                )

    print_success("Cross-service onboarding consistency validation completed")


def validate_branch_slug(data: Dict):
    """Validate that team_name in the YAML matches the target branch name.

    In the per-team branch model each onboarding branch is named
    <team_slug>-onboarding (e.g. observability-onboarding).
    PR_BASEBRANCH is set by One Pipeline to the branch the PR targets,
    so we can derive the expected team slug directly from it without
    needing any extra CLI argument.

    Rules:
      - If PR_BASEBRANCH is not set (e.g. local run) the check is skipped.
      - If the branch does not end with '-onboarding' the check is skipped
        (not an onboarding branch — nothing to enforce).
      - The team slug is PR_BASEBRANCH with the '-onboarding' suffix removed.
      - The team slug derived from team_name (lower-case, spaces → hyphens)
        must exactly match that branch-derived slug.
    """
    import os

    print_info("Validating team slug against target branch name...")

    pr_basebranch = os.environ.get('PR_BASEBRANCH', '').strip()

    if not pr_basebranch:
        print_warning("PR_BASEBRANCH is not set — branch slug check skipped (local run?)")
        return

    if not pr_basebranch.endswith('-onboarding'):
        print_info(f"Target branch '{pr_basebranch}' is not an onboarding branch — slug check skipped")
        return

    # Derive the expected team slug from the branch name
    expected_slug = pr_basebranch[: -len('-onboarding')]

    team_name = data.get('team_name', '')
    if not team_name or team_name == 'myteamname':
        print_warning("team_name is missing or still a placeholder — branch slug check skipped")
        return

    actual_slug = team_name.lower().replace(' ', '-')

    if actual_slug != expected_slug:
        print_error(f"team_name slug does not match the target branch")
        print_error(f"  Target branch  : {pr_basebranch}")
        print_error(f"  Expected slug  : {expected_slug}  (derived from branch name)")
        print_error(f"  team_name      : {team_name}")
        print_error(f"  Actual slug    : {actual_slug}  (derived from team_name)")
        print_info( f"  Fix: set team_name to the team that owns branch '{pr_basebranch}',")
        print_info( f"       or open your PR against the correct '<team_slug>-onboarding' branch.")
    else:
        print_success(f"team_name slug matches target branch: '{actual_slug}' == '{expected_slug}'")


def validate_pr_head_branch():
    """Validate that the PR head branch (PR_BRANCH) does not end with '-onboarding'.

    The '*-onboarding' suffix is reserved exclusively for team base branches
    and must never be used as a contributor working branch name. This rule is
    unconditional — no value before '-onboarding' is acceptable as a PR head
    branch (e.g. fabric-onboarding, my-feature-onboarding, test-onboarding
    are all rejected).

    Contributor working branches must use any other naming convention,
    e.g. feat/add-my-service, fix/update-psirt, TICKET-1234.

    Rules:
      - If PR_BRANCH is not set (local run) the check is skipped.
      - If PR_BRANCH ends with '-onboarding' → ERROR, unconditionally.
    """
    import os

    print_info("Validating PR head branch name...")

    pr_branch = os.environ.get('PR_BRANCH', '').strip()

    if not pr_branch:
        print_warning("PR_BRANCH is not set — head branch check skipped (local run?)")
        return

    if pr_branch.endswith('-onboarding'):
        slug = pr_branch[:-len('-onboarding')]
        print_error(f"PR head branch '{pr_branch}' ends with the reserved '-onboarding' suffix")
        print_error(f"  No branch named '*-onboarding' is acceptable as a PR head branch")
        print_error(f"  This suffix is reserved for team base branches only")
        print_info( f"  Rename your working branch — for example:")
        print_info( f"    feat/{slug}-<description>")
        print_info( f"    fix/{slug}-<description>")
        print_info( f"    <TICKET-ID>-{slug}-<description>")
    else:
        print_success(f"PR head branch name is valid: '{pr_branch}'")


def main():
    global debug_mode
    
    parser = argparse.ArgumentParser(
        description='Validate CI/CD onboarding YAML file for completeness and correctness'
    )
    parser.add_argument(
        'yaml_file',
        help='Path to <service_name>-onboarding.yaml file to validate'
    )
    parser.add_argument(
        '--debug',
        action='store_true',
        help='Enable debug logging for detailed validation information'
    )
    
    args = parser.parse_args()
    debug_mode = args.debug
    
    print("=" * 50)
    print("  CI/CD Onboarding YAML Validation")
    print("=" * 50)
    if debug_mode:
        print(f"{YELLOW}[DEBUG MODE ENABLED]{NC}")
    print()
    
    print_debug(f"Loading YAML file: {args.yaml_file}")
    data = load_yaml(args.yaml_file)
    print_debug(f"YAML file loaded successfully with {len(data)} top-level keys")

    validate_cicd_profile(data)
    print()

    validate_filename(args.yaml_file, data)
    print()

    validate_branch_slug(data)
    print()

    validate_pr_head_branch()
    print()

    validate_team_onboarding_consistency(args.yaml_file, data)
    print()

    validate_team_name(data)
    print()
    
    validate_service_name(data)
    print()
    
    validate_functional_ids(data)
    print()
    
    validate_inventory_repo(data)
    print()
    
    validate_incident_repo(data)
    print()
    
    validate_compliance_bucket(data)
    print()
    
    validate_app_repo(data)
    print()
    
    validate_psirt_id(data)
    print()

    validate_servicenow_crn(data)
    print()

    validate_ibm_cloud_accounts(data)
    print()
    
    validate_slack_config(data)
    print()
    
    validate_secrets(data)
    print()
    
    validate_mandatory_files(data)
    print()
    
    validate_optional_files(data)
    print()
    
    validate_deployment_targets(data)
    print()
    
    validate_external_services(data)
    print()
    
    validate_repo_consistency(data)
    print()
    
    # Summary
    print("=" * 50)
    print("  Validation Summary")
    print("=" * 50)
    
    if errors == 0 and warnings == 0:
        print_success("All validations passed! ✓")
        sys.exit(0)
    elif errors == 0:
        print_warning(f"Validation completed with {warnings} warning(s)")
        sys.exit(0)
    else:
        print_error(f"Validation failed with {errors} error(s) and {warnings} warning(s)")
        sys.exit(1)

if __name__ == '__main__':
    main()


