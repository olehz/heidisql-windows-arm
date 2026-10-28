# HeidiSQL Windows ARM64 (Qt6 preview)

GitHub Actions build of the HeidiSQL `lazarus` branch with the Qt6 widgetset
(`lazbuild --cpu=aarch64 --os=win64 --ws=qt6`) on the `windows-11-arm` runner.

The official Windows v13 preview is x64 and does not pass `--ws=qt6`.
Client libraries shipped in `extra/dll` are x64; an ARM64 process cannot load them.
This workflow still tries to produce `heidisql.exe` and uploads it when the link succeeds.
