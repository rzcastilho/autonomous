let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
// Feature 040: while "follow conversations" is on, keep the live conversation
// scrolled to its newest entry — on every appended row and on every switch to
// the next session. Scrolling up to read pauses it until the reader returns to
// the bottom; turning the toggle on jumps to the bottom at once.
const nearBottom = (el) => el.scrollHeight - el.scrollTop - el.clientHeight < 80;

const scrollParent = (el) => {
  for (let node = el.parentElement; node; node = node.parentElement) {
    const overflow = getComputedStyle(node).overflowY;
    if ((overflow === "auto" || overflow === "scroll") && node.scrollHeight > node.clientHeight) {
      return node;
    }
  }
  return document.scrollingElement || document.documentElement;
};

const FollowTail = {
  following() {
    return this.el.dataset.follow === "true";
  },
  toBottom() {
    const box = scrollParent(this.el);
    box.scrollTop = box.scrollHeight;
  },
  mounted() {
    this.wasFollowing = this.following();
    if (this.wasFollowing) this.toBottom();
  },
  beforeUpdate() {
    this.stick = nearBottom(scrollParent(this.el));
  },
  updated() {
    const following = this.following();
    if (following && (!this.wasFollowing || this.stick)) this.toBottom();
    this.wasFollowing = following;
  }
};

// Feature 045: the Mission Control telemetry feed can be hidden; remember the
// choice per browser. Storage may be unavailable (private window, blocked
// site data) — every access is guarded and failure is a no-op.
const TELEMETRY_KEY = "autonomous.mc.telemetry";

const TelemetryPref = {
  mounted() {
    try {
      if (window.localStorage.getItem(TELEMETRY_KEY) === "hidden") {
        this.pushEvent("telemetry_restore", { hidden: true });
      }
    } catch (_e) {}

    this.handleEvent("telemetry_pref", ({ hidden }) => {
      try {
        window.localStorage.setItem(TELEMETRY_KEY, hidden ? "hidden" : "shown");
      } catch (_e) {}
    });
  }
};

let liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
  params: { _csrf_token: csrfToken },
  hooks: { FollowTail, TelemetryPref }
});

liveSocket.connect();
window.liveSocket = liveSocket;

window.addEventListener("phx:copy", (e) => {
  if (navigator.clipboard) navigator.clipboard.writeText(e.detail.text);
});
