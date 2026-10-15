const button = document.querySelector('#copy');
const feedback = document.querySelector('#feedback');
button?.addEventListener('click', async () => {
  try { await navigator.clipboard.writeText(location.href); feedback.textContent = 'Link kopiert.'; }
  catch { feedback.textContent = 'Kopiere die Adresse aus der Adressleiste deines Browsers.'; }
});
const video = document.querySelector('video');
video?.addEventListener('error', () => { feedback.textContent = 'Die Aufnahme konnte nicht geladen werden. Prüfe deine Verbindung oder frage nach einem neuen Link.'; });
