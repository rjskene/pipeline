// app.js — renders window.TASKS into the ledger table: one <tr> per task, in
// id order, cells in the `list` column order (id, status, priority, title).
(function () {
  var COLUMNS = ["id", "status", "priority", "title"];
  var tbody = document.querySelector("#tasks tbody");
  var tasks = (window.TASKS || []).slice().sort(function (a, b) {
    return a.id - b.id;
  });

  tasks.forEach(function (task) {
    var tr = document.createElement("tr");
    COLUMNS.forEach(function (col) {
      var td = document.createElement("td");
      td.textContent = String(task[col]);
      tr.appendChild(td);
    });
    tbody.appendChild(tr);
  });
})();
