// trivy-version resolves the highest published patch of an aquasec/trivy
// minor (e.g. 0.70 → 0.70.3) by querying Docker Hub's tags API. Used by
// cloudbuild.yaml: the Trivy scan step pins to a deliberate minor but
// floats on patch.
//
// Inputs (env):
//   TRIVY_MINOR     — minor to resolve, e.g. "0.70". Required.
//   TRIVY_FALLBACK  — last-known-good full semver, used if lookup fails.
//                     e.g. "0.70.0". Required.
//
// Output: prints the resolved version (no `v` prefix, no whitespace) to
// stdout. On any error reaching/parsing Docker Hub, prints the fallback to
// stdout and the reason to stderr, then exits 0 — the pipeline continues
// with a known-good version rather than failing on a transient network
// issue. If TRIVY_FALLBACK is also missing, exits non-zero.

package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"regexp"
	"sort"
	"strconv"
	"time"
)

const dockerHubTagsURL = "https://hub.docker.com/v2/repositories/aquasec/trivy/tags?page_size=100"

func main() {
	minor := os.Getenv("TRIVY_MINOR")
	fallback := os.Getenv("TRIVY_FALLBACK")

	if fallback == "" {
		fmt.Fprintln(os.Stderr, "trivy-version: TRIVY_FALLBACK is required")
		os.Exit(1)
	}
	if minor == "" {
		degrade(fallback, "TRIVY_MINOR is empty")
		return
	}

	resolved, err := resolveLatestPatch(minor)
	if err != nil {
		degrade(fallback, err.Error())
		return
	}
	fmt.Println(resolved)
}

func degrade(fallback, reason string) {
	fmt.Fprintf(os.Stderr, "trivy-version: falling back to %s (%s)\n", fallback, reason)
	fmt.Println(fallback)
}

func resolveLatestPatch(minor string) (string, error) {
	patch := regexp.MustCompile("^" + regexp.QuoteMeta(minor) + `\.(\d+)$`)

	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Get(dockerHubTagsURL)
	if err != nil {
		return "", fmt.Errorf("GET %s: %w", dockerHubTagsURL, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("docker hub returned %s", resp.Status)
	}

	var body struct {
		Results []struct {
			Name string `json:"name"`
		} `json:"results"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return "", fmt.Errorf("decode json: %w", err)
	}

	var patches []int
	for _, t := range body.Results {
		m := patch.FindStringSubmatch(t.Name)
		if m == nil {
			continue
		}
		p, err := strconv.Atoi(m[1])
		if err != nil {
			continue
		}
		patches = append(patches, p)
	}

	if len(patches) == 0 {
		return "", fmt.Errorf("no tags match %s.X in the first 100 results", minor)
	}

	sort.Sort(sort.Reverse(sort.IntSlice(patches)))
	return fmt.Sprintf("%s.%d", minor, patches[0]), nil
}
