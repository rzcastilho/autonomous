let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
let liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
  params: { _csrf_token: csrfToken }
});

liveSocket.connect();
window.liveSocket = liveSocket;

window.addEventListener("phx:copy", (e) => {
  if (navigator.clipboard) navigator.clipboard.writeText(e.detail.text);
});
