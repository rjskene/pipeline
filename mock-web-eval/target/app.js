// mock-web-eval — vanilla JS, no framework. <=100 lines.
(function () {
  'use strict';

  // 1. Toggle button flips panel visibility AND indicator state.
  const panel = document.getElementById('toggle-panel');
  const indicator = document.getElementById('toggle-indicator');
  document.getElementById('toggle-btn').addEventListener('click', function () {
    const wasHidden = panel.hasAttribute('hidden');
    if (wasHidden) {
      panel.removeAttribute('hidden');
      indicator.classList.remove('off');
      indicator.classList.add('on');
      indicator.textContent = 'on';
    } else {
      panel.setAttribute('hidden', '');
      indicator.classList.remove('on');
      indicator.classList.add('off');
      indicator.textContent = 'off';
    }
  });

  // 2. Form submit echoes input into the DOM.
  const form = document.getElementById('echo-form');
  const input = document.getElementById('echo-input');
  const output = document.getElementById('echo-output');
  form.addEventListener('submit', function (e) {
    e.preventDefault();
    output.textContent = 'You said: ' + input.value;
  });

  // 3. Add/remove list items mutate state.
  const list = document.getElementById('item-list');
  const addBtn = document.getElementById('item-add');
  let counter = 0;
  addBtn.addEventListener('click', function () {
    counter += 1;
    const li = document.createElement('li');
    li.textContent = 'Item ' + counter + ' ';
    const removeBtn = document.createElement('button');
    removeBtn.type = 'button';
    removeBtn.textContent = 'Remove';
    removeBtn.addEventListener('click', function () {
      li.remove();
    });
    li.appendChild(removeBtn);
    list.appendChild(li);
  });

  // 4. Counter buttons increment/decrement a running total (no bounds).
  const counterValue = document.getElementById('counter-value');
  let count = 0;
  document.getElementById('counter-inc').addEventListener('click', function () {
    count += 1;
    counterValue.textContent = String(count);
  });
  document.getElementById('counter-dec').addEventListener('click', function () {
    count -= 1;
    counterValue.textContent = String(count);
  });

  // 5. Footer build-timestamp set at page load.
  const stamp = document.getElementById('build-timestamp');
  if (stamp) {
    stamp.textContent = 'Built: ' + new Date().toLocaleString();
  }
})();
