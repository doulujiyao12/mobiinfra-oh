'use strict';

const message = document.getElementById('message');
let activeRevision = 0;

window.renderCodexMath = (html, revision, dark) => {
  activeRevision = revision;
  document.body.classList.toggle('dark', dark);
  // Only the markup built from escaped Markdown nodes is passed into this page.
  message.innerHTML = html;
  if (!window.katex) return;
  for (const node of message.querySelectorAll('[data-tex]')) {
    try {
      const markup = window.katex.renderToString(node.dataset.tex, {
        displayMode: node.classList.contains('math-block'),
        throwOnError: true,
        trust: false,
        strict: 'ignore',
        maxSize: 20,
        maxExpand: 500
      });
      node.innerHTML = markup;
    } catch {
      // The untouched source stays readable while a response is streaming or if a command is unsupported.
    }
    node.removeAttribute('data-tex');
  }
};

message.addEventListener('click', event => {
  const link = event.target.closest('a[data-link]');
  if (!link) return;
  event.preventDefault();
  window.codexMathLinks?.open(Number(link.dataset.link), activeRevision);
});
