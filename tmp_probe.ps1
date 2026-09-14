$ids = 13,15,16,17,21,27,30,31,32,33,34,35,49,50
foreach ($i in $ids) {
  $f = "C:/rebase/videoCRM/projects/$i/final.mp4"
  $d = (ffprobe -v error -select_streams v:0 -show_entries stream=width,height -show_entries format=duration -of "csv=p=0" $f) -join ' '
  $m = (Get-Item $f).LastWriteTime.ToString('MM-dd HH:mm')
  Write-Output ("{0}`t{1}`t{2}" -f $i, $d, $m)
}
