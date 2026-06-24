// Trigger a browser download of `text` as a file named `filename`. Uses a
// transient blob URL and a synthetic <a> click; the link is removed and the
// URL revoked immediately after, so nothing is left behind.

export function downloadText(filename: string, text: string): void {
  const blob = new Blob([text], { type: "text/plain;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);
}
