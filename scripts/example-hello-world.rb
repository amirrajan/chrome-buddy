restart_browser
goto "http://lefthandedgoat.github.io/canopy/testpages/"
eval_js <<-S
  document.querySelector("#testfield1").value = "Hello, World!"
S
