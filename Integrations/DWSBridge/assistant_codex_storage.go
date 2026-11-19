// Copyright 2026 DWS Assistant contributors
// SPDX-License-Identifier: Apache-2.0
package helpers

import (
	"errors"
	"os"
	"path/filepath"
	"syscall"
)

var errAssistantCodexStorage = errors.New("dedicated Codex storage unavailable")

func assistantNativeCodexHome() (string, error) {
	if path := os.Getenv("CODEX_HOME"); path != "" {
		if !filepath.IsAbs(path) {
			return "", errors.New("Codex home must be absolute")
		}
		return filepath.Clean(path), nil
	}
	home, err := os.UserHomeDir()
	return filepath.Join(home, ".codex"), err
}

func assistantPrepareCodexHome(destination string) error {
	if !filepath.IsAbs(destination) {
		return errors.New("dedicated Codex home must be absolute")
	}
	native, err := assistantNativeCodexHome()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(destination, 0700); err != nil {
		return err
	}
	actual, err := filepath.EvalSymlinks(destination)
	if err != nil {
		return err
	}
	source, sourceErr := filepath.EvalSymlinks(native)
	if sourceErr == nil && actual == source {
		return errors.New("dedicated Codex home must differ from desktop storage")
	}
	lock, err := os.OpenFile(filepath.Join(destination, ".assistant-storage.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		return err
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)

	// Share only engine configuration/login inputs. Never link sessions,
	// databases, writer locks, queues, logs, or the desktop's entire home.
	shared := []string{"config.toml", "auth.json", ".credentials.json", "AGENTS.md", "AGENTS.override.md", "instructions.md", "skills", "rules", "agents", "prompts", "plugins"}
	profiles, _ := filepath.Glob(filepath.Join(native, "*.config.toml"))
	for _, path := range profiles {
		shared = append(shared, filepath.Base(path))
	}
	for _, name := range shared {
		target := filepath.Join(native, name)
		if _, err := os.Stat(target); errors.Is(err, os.ErrNotExist) {
			continue
		} else if err != nil {
			return err
		}
		link := filepath.Join(destination, name)
		if _, err := os.Lstat(link); err == nil {
			continue
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
		if err := os.Symlink(target, link); err != nil {
			return err
		}
	}
	return nil
}
