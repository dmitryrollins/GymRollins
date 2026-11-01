// Leave APP_STORE_URL empty until the app is released: the button stays hidden.
const APP_STORE_URL = ''

// The same characters and length the app accepts, so nothing else can be put into the app's link.
const WORKOUT = /^#[A-Za-z0-9_.-]{1,1024}$/

export function appLink(hash) {
  return WORKOUT.test(hash) ? `gymrollins://w${hash}` : null
}

export function appStoreLink(address) {
  return address.startsWith('https://') ? address : null
}

function show(id, href) {
  const button = document.getElementById(id)
  if (!href) return
  button.href = href
  button.hidden = false
}

if (typeof document !== 'undefined') {
  show('open', appLink(location.hash))
  show('store', appStoreLink(APP_STORE_URL))
}
