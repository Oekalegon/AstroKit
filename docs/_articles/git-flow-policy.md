---
layout: article
title: "Git Workflow and Merge Policy"
date: 2026-01-14 14:30:00 +0000
series: "Development"
series_order: 1
categories: github git-flow collaboration pull-requests
published: true
---

This document describes the Git workflow and merge policies for this repository. It explains how to create branches, when to open pull requests, and which branches are allowed to merge into `develop` and `main`.

---

## Branch Types and Their Purpose

| Branch Type | Naming Convention | Purpose |
|------------|-----------------|--------|
| **Main** | `main` | Production-ready code. Only updated via `release/*` or `hotfix/*` branches. |
| **Development** | `develop` | Integration branch. All feature work merges here first. |
| **Feature** | `feature/<name>` | Work on new features. Branch off from `develop`. Merge back into `develop` when done. |
| **Release** | `release/<version>` | Prepares a new release. Branch off from `develop`. Merge into `main` and back into `develop`. |
| **Hotfix** | `hotfix/<name>` | Fixes production bugs. Branch off from `main`. Merge into `main` and back into `develop`. |

---

## General Rules

- **All changes must go through pull requests (PRs).** Direct pushes to `main` or `develop` are blocked.
- **Status checks are required**:
  - The **Enforce merge policy** workflow must pass before a PR can be merged.
- **PR base branch rules**:
  - Feature branches → `develop`
  - Release branches → `main` (and back to `develop`)
  - Hotfix branches → `main` (and back to `develop`)

---

## Branch Creation Guidelines

### **Feature Branches**
1. Branch off from `develop`
   ```bash
   git checkout develop
   git pull
   git checkout -b feature/<name>
   ```
2.	Work on your feature and commit locally.
3.	Push to origin:
```
git push -u origin feature/<name>
```

4.	Open a PR targeting develop.

### Release Branches
1.	Branch off from develop when you are ready to release a version:
```
git checkout develop
git pull
git checkout -b release/<version>
```

2.	Perform any release-specific testing or minor fixes.
3.	Open a PR targeting main.
4.	Once merged into main, back-merge into develop:
```
git checkout develop
git pull
git merge main
git push
```

### Hotfix Branches
1.	Branch off from main for critical production fixes:
```
git checkout main
git pull
git checkout -b hotfix/<name>
```

2.	Fix the issue, commit, push, and open a PR targeting main.
3.	After merging into main, back-merge into develop.

### Pull Request Guidelines
* Always target the correct base branch:
* Feature → develop
* Release → main
* Hotfix → main
* Status checks:
* PRs must pass the Enforce merge policy workflow before merging.
* Reviews:
* Assign at least 1 reviewer for all PRs (optional, depending on team policy)
* Merging:
* Use the “Merge pull request” button. Do not push merges directly.
* After merging release or hotfix PRs, back-merge to develop.

### Workflow Diagram
```
          Feature Branches
                 |
                 v
            develop (protected)
                 |
                 v
       release/x.y.z (protected)
                 |
                 v
            main (protected)
```

* The Enforce merge policy workflow runs on all PRs to develop and main.
* Only release/* and hotfix/* branches are allowed to merge into main.
* Feature branches merge into develop first.

### Key Points for Developers
* Always create feature branches from develop.
* Only create release branches when preparing a production release.
* Hotfix branches come from main for urgent production fixes.
* Never merge directly into main or develop — always use PRs.
* Make sure all status checks pass before merging.
* Back-merge release or hotfix branches into develop to keep all branches up-to-date.