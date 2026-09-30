import { useCallback, useEffect, useRef, useState } from "react";
import { appSetting, setAppSetting, useAppSetting } from "../app-settings.js";

// Check for Updates, as the Mac app's UpdateCheck runs it: the menu command always answers;
// the automatic check runs shortly after launch and then daily, and says something only when
// there is a release this person has not skipped. The backend reads the feed and downloads,
// verifies and opens the installer (backend.updates); this hook paces it and says what happened.
// Include Pre-releases widens every check to releases published before they are final.

const DAY = 24 * 60 * 60 * 1000;
const LAUNCH_DELAY = 5000;

async function settle(updates, answer, busy) {
  while (busy.includes(answer.state)) {
    await new Promise((resolve) => setTimeout(resolve, 200));
    answer = await updates.status();
  }
  return answer;
}

/** A byte count as the Mac's file-size formatter reads it: "12.3 MB". */
export function formatBytes(bytes) {
  if (!(bytes > 0)) return "Zero KB";
  const units = ["bytes", "KB", "MB", "GB"];
  let value = bytes,
    unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit += 1;
  }
  return `${unit >= 2 ? value.toFixed(1) : Math.round(value)} ${units[unit]}`;
}

/** What a finished check says, in the Mac app's alerts; null when an automatic one says nothing. */
export function checkOutcome(answer, { manual, skipped = null }) {
  if (answer.state === "available") {
    if (!manual && answer.release === skipped) return null;
    return {
      kind: "available",
      // A pre-release often keeps the running marketing version; its build tells them apart.
      version: answer.current?.startsWith(`${answer.version} `)
        ? answer.release
        : answer.version,
      release: answer.release,
      current: answer.current,
      notes: answer.notes ?? null,
      allowSkip: !manual,
    };
  }
  if (!manual) return null;
  if (answer.state === "current")
    return {
      kind: "notice",
      title: "You're up to date",
      message: `Fotufilm ${answer.current} is the newest release.`,
    };
  return {
    kind: "notice",
    warning: true,
    title: "Fotufilm could not check for updates",
    message: answer.message ?? "The update feed could not be reached.",
  };
}

export default function useUpdates({ backend, setDialog }) {
  const updates = backend.updates;
  const [update, setUpdate] = useState(null);
  const running = useRef(false);

  const check = useCallback(
    async (manual) => {
      if (!updates || running.current) return;
      running.current = true;
      try {
        const answer = await settle(
          updates,
          await updates.check({ prereleases: appSetting("updatePrereleases") === true }),
          ["checking"],
        );
        if (answer.state === "current" || answer.state === "available")
          setAppSetting("updateLastCheck", Date.now());
        const outcome = checkOutcome(answer, {
          manual,
          skipped: appSetting("updateSkipped"),
        });
        if (outcome) {
          setUpdate(outcome);
          setDialog("update");
        }
      } catch (error) {
        if (manual) {
          setUpdate(checkOutcome({ state: "failed", message: error.message }, { manual }));
          setDialog("update");
        }
      } finally {
        running.current = false;
      }
    },
    [updates, setDialog],
  );

  // Shortly after launch, then whenever a day has passed since the feed last answered.
  useEffect(() => {
    if (!updates) return;
    const due = () =>
      appSetting("updateChecksAutomatically") !== false &&
      !(Date.now() - (appSetting("updateLastCheck") ?? 0) < DAY);
    const run = () => due() && check(false);
    const launch = setTimeout(run, LAUNCH_DELAY);
    const daily = setInterval(run, 60 * 60 * 1000);
    return () => {
      clearTimeout(launch);
      clearInterval(daily);
    };
  }, [updates, check]);

  // Turning Include Pre-releases on asks at once, rather than up to a day later.
  const prereleases = useAppSetting("updatePrereleases") === true;
  const asked = useRef(prereleases);
  useEffect(() => {
    if (prereleases && !asked.current && appSetting("updateChecksAutomatically") !== false)
      check(false);
    asked.current = prereleases;
  }, [prereleases, check]);

  const install = useCallback(async () => {
    const offer = update;
    setUpdate({ kind: "downloading", version: offer.version, bytes: 0, total: 0 });
    let answer = await updates.install();
    while (answer.state === "downloading") {
      setUpdate({ kind: "downloading", version: offer.version, bytes: answer.bytes, total: answer.total });
      await new Promise((resolve) => setTimeout(resolve, 200));
      answer = await updates.status();
    }
    if (answer.state === "opened") {
      setUpdate(null);
      setDialog(null);
    } else if (answer.state === "downloadFailed") {
      setUpdate({
        kind: "notice",
        warning: true,
        title: answer.verify
          ? "The update could not be verified."
          : "The update could not be downloaded.",
        message: answer.message,
      });
    } else {
      // Cancelled: the offer stands again.
      setUpdate(offer);
    }
  }, [update, updates, setDialog]);

  return {
    update,
    checkForUpdates: updates ? () => check(true) : undefined,
    installUpdate: install,
    cancelUpdate: () => updates?.cancel(),
    skipUpdate: () => {
      if (update?.release) setAppSetting("updateSkipped", update.release);
      setDialog(null);
    },
    openReleaseNotes: () => updates?.notes().catch(() => {}),
  };
}
