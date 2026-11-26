# Set up GitHub SSH access and GPG commit signing.
# Run `make help` to list targets and settings.

SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.ONESHELL:
.SILENT:
.NOTPARALLEL:
.DEFAULT_GOAL := help

# Settings: override with `make <target> NAME=value`.
EMAIL ?= $(shell git config --global --get user.email 2>/dev/null)
NAME ?= $(shell git config --global --get user.name 2>/dev/null)
KEY_TITLE ?= $(shell uname -n)
SSH_KEY ?= $(HOME)/.ssh/id_ed25519
SSH_CONFIG ?= $(HOME)/.ssh/config
KNOWN_HOSTS ?= $(HOME)/.ssh/known_hosts
GPG_KEY_ID ?=
GPG_EXPIRE ?= 2y
GH_SCOPES ?= write:public_key,write:gpg_key

# Key that gpg looks up: GPG_KEY_ID if set, else the key whose email is EMAIL.
GPG_SELECTOR = $(if $(strip $(GPG_KEY_ID)),$(GPG_KEY_ID),<$(EMAIL)>)

# Shell command that prints the fingerprint of a usable (not expired or revoked) secret key.
GPG_FPR = { gpg --list-secret-keys --with-colons -- "$(GPG_SELECTOR)" 2>/dev/null || true; } \
    | awk -F: '/^sec:/ { ok = ($$2 !~ /[idre]/) } /^fpr:/ && ok { print $$10; exit }'

# Let pinentry ask for the passphrase in this terminal.
GPG_TTY_EXPORT = if [ -z "$${GPG_TTY:-}" ] && tty -s; then export GPG_TTY="$$(tty)"; fi

# Stop with a hint when a setting is empty: $(call require,EMAIL)
require = [ -n "$(strip $($(1)))" ] || { echo "$(1) is empty. Run: make $@ $(1)=..." >&2; exit 1; }

.PHONY: help check status setup gh-auth \
    ssh ssh-key ssh-agent ssh-config ssh-known-hosts ssh-upload ssh-test \
    gpg gpg-key gpg-git gpg-upload gpg-test

help: ## Show targets and settings
	echo "Usage: make <target> [VAR=value]"
	echo
	echo "Targets:"
	awk 'BEGIN { FS = ":.*## " } /^[a-z][a-z-]*:.*## / { printf "  %-16s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	echo
	echo "Settings:"
	printf '  %-12s %s\n' \
		EMAIL "$(EMAIL)" \
		NAME "$(NAME)" \
		KEY_TITLE "$(KEY_TITLE)" \
		SSH_KEY "$(SSH_KEY)" \
		SSH_CONFIG "$(SSH_CONFIG)" \
		KNOWN_HOSTS "$(KNOWN_HOSTS)" \
		GPG_KEY_ID "$(GPG_KEY_ID)" \
		GPG_EXPIRE "$(GPG_EXPIRE)" \
		GH_SCOPES "$(GH_SCOPES)"

check: ## Check required tools and GitHub CLI login
	missing=0

	for tool in git ssh ssh-keygen ssh-add gpg gh awk; do
		if command -v "$$tool" >/dev/null 2>&1; then
			echo "ok       $$tool"
		else
			echo "missing  $$tool"
			missing=1
		fi
	done

	if gh auth status -h github.com >/dev/null 2>&1; then
		echo "ok       gh login"
	else
		echo "missing  gh login (run: make gh-auth)"
		missing=1
	fi

	exit "$$missing"

status: ## Show the current SSH, GPG and git signing state
	echo "SSH key:     $$(ssh-keygen -lf "$(SSH_KEY).pub" 2>/dev/null || echo "missing ($(SSH_KEY))")"
	fpr="$$($(GPG_FPR))"
	echo "GPG key:     $${fpr:-missing}"
	echo "signingkey:  $$(git config --global --get user.signingkey || echo unset)"
	echo "gpgsign:     $$(git config --global --get commit.gpgsign || echo unset)"

	if gh auth status -h github.com >/dev/null 2>&1; then
		echo
		echo "GitHub SSH keys:"
		gh ssh-key list || true
		echo
		echo "GitHub GPG keys:"
		gh gpg-key list || true
	else
		echo "GitHub CLI:  not logged in (run: make gh-auth)"
	fi

setup: gh-auth ssh gpg ## Run the full SSH and GPG setup

gh-auth: ## Log in to GitHub CLI with the scopes for adding keys
	if gh auth status -h github.com >/dev/null 2>&1; then
		gh auth refresh -h github.com -s "$(GH_SCOPES)"
	else
		gh auth login -h github.com -p ssh --skip-ssh-key -s "$(GH_SCOPES)"
	fi

# ---- SSH ----

ssh: ssh-key ssh-agent ssh-config ssh-known-hosts ssh-upload ssh-test ## Set up SSH access to GitHub

ssh-key: ## Create the SSH key (asks for a passphrase)
	if [ -f "$(SSH_KEY)" ]; then
		echo "SSH key exists: $(SSH_KEY)"
		exit 0
	fi

	$(call require,EMAIL)
	mkdir -p -m 700 "$(dir $(SSH_KEY))"
	ssh-keygen -t ed25519 -C "$(EMAIL)" -f "$(SSH_KEY)"

ssh-agent: ssh-key ## Add the SSH key to the running ssh-agent
	if [ -z "$${SSH_AUTH_SOCK:-}" ]; then
		echo "No ssh-agent running; skipped. AddKeysToAgent adds the key on first use."
		exit 0
	fi

	if ssh-add -L 2>/dev/null | grep -qF "$$(cut -d' ' -f2 "$(SSH_KEY).pub")"; then
		echo "SSH key already in ssh-agent"
	else
		ssh-add "$(SSH_KEY)"
	fi

ssh-config: ssh-key ## Add a github.com entry to the SSH config
	mkdir -p -m 700 "$(dir $(SSH_CONFIG))"
	touch "$(SSH_CONFIG)"
	chmod 600 "$(SSH_CONFIG)"

	if grep -qE '^[[:space:]]*Host[[:space:]]+(.*[[:space:]])?github\.com([[:space:]]|$$)' "$(SSH_CONFIG)"; then
		echo "$(SSH_CONFIG) already has a github.com entry; check that it uses $(SSH_KEY)"
	else
		printf '\nHost github.com\n  HostName github.com\n  User git\n  IdentityFile %s\n  IdentitiesOnly yes\n  AddKeysToAgent yes\n' "$(SSH_KEY)" >> "$(SSH_CONFIG)"
		echo "Added github.com entry to $(SSH_CONFIG)"
	fi

ssh-known-hosts: ## Trust GitHub host keys taken from the GitHub API
	mkdir -p -m 700 "$(dir $(KNOWN_HOSTS))"

	if ssh-keygen -F github.com -f "$(KNOWN_HOSTS)" >/dev/null 2>&1; then
		echo "github.com already in $(KNOWN_HOSTS)"
		exit 0
	fi

	entries="$$(gh api meta --jq '.ssh_keys[] | "github.com " + .')"
	[ -n "$$entries" ] || { echo "GitHub API returned no SSH host keys" >&2; exit 1; }
	printf '%s\n' "$$entries" >> "$(KNOWN_HOSTS)"
	echo "Added GitHub host keys to $(KNOWN_HOSTS)"

ssh-upload: ssh-key ## Upload the SSH public key to GitHub
	pub="$$(cut -d' ' -f1-2 "$(SSH_KEY).pub")"
	keys="$$(gh api --paginate user/keys --jq '.[].key')" \
		|| { echo "Cannot read your GitHub SSH keys. Run: make gh-auth" >&2; exit 1; }

	if grep -qxF "$$pub" <<< "$$keys"; then
		echo "SSH key already on GitHub"
	else
		gh ssh-key add "$(SSH_KEY).pub" --title "$(KEY_TITLE)" --type authentication
	fi

ssh-test: ## Test SSH login to GitHub
	out="$$(ssh -T git@github.com 2>&1 || true)"
	echo "$$out"
	grep -q "successfully authenticated" <<< "$$out" \
		|| { echo "SSH test failed" >&2; exit 1; }

# ---- GPG ----

gpg: gpg-key gpg-git gpg-upload gpg-test ## Set up GPG commit signing for GitHub

gpg-key: ## Create the GPG signing key (asks for a passphrase)
	fpr="$$($(GPG_FPR))"

	if [ -n "$$fpr" ]; then
		echo "GPG key exists: $$fpr"
		exit 0
	fi

	if [ -n "$(strip $(GPG_KEY_ID))" ]; then
		echo "No usable secret key for GPG_KEY_ID=$(GPG_KEY_ID)" >&2
		exit 1
	fi

	$(call require,EMAIL)
	$(call require,NAME)
	$(GPG_TTY_EXPORT)
	gpg --quick-generate-key "$(NAME) <$(EMAIL)>" ed25519 sign "$(GPG_EXPIRE)"
	echo "Created GPG key: $$($(GPG_FPR))"

gpg-git: gpg-key ## Make git sign commits and tags with the GPG key
	fpr="$$($(GPG_FPR))"
	git config --global user.signingkey "$$fpr"
	git config --global gpg.format openpgp
	git config --global commit.gpgsign true
	git config --global tag.gpgsign true
	echo "git now signs commits and tags with $$fpr"

	git_email="$$(git config --global --get user.email || true)"

	if [ -z "$$git_email" ]; then
		git config --global user.email "$(EMAIL)"
		echo "Set git user.email to $(EMAIL)"
	elif [ "$$git_email" != "$(EMAIL)" ]; then
		echo "Warning: git user.email ($$git_email) differs from the key email ($(EMAIL))" >&2
	fi

	if [ -z "$$(git config --global --get user.name || true)" ] && [ -n "$(NAME)" ]; then
		git config --global user.name "$(NAME)"
		echo "Set git user.name to $(NAME)"
	fi

	echo "Note: $(EMAIL) must be a verified email on GitHub to get the Verified badge."

	if [ -z "$${GPG_TTY:-}" ]; then
		echo "Tip: add this line to your shell rc file so gpg can ask for the passphrase:"
		echo '  export GPG_TTY=$$(tty)'
	fi

gpg-upload: gpg-key ## Upload the GPG public key to GitHub
	fpr="$$($(GPG_FPR))"
	ids="$$(gh api --paginate user/gpg_keys --jq '.[].key_id')" \
		|| { echo "Cannot read your GitHub GPG keys. Run: make gh-auth" >&2; exit 1; }

	if grep -qixF "$${fpr: -16}" <<< "$$ids"; then
		echo "GPG key already on GitHub"
		exit 0
	fi

	tmp="$$(mktemp)"
	trap 'rm -f "$$tmp"' EXIT
	gpg --armor --export "$$fpr" > "$$tmp"
	gh gpg-key add "$$tmp" --title "$(KEY_TITLE)"

gpg-test: gpg-key ## Test signing with the GPG key
	fpr="$$($(GPG_FPR))"
	$(GPG_TTY_EXPORT)
	echo test | gpg --clearsign --local-user "$$fpr" > /dev/null
	echo "GPG signing works with $$fpr"
