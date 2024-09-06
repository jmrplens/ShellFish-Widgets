# ShellFish-Widgets
Bash scripts to send information from the server to the widget.

It is important to have the `.shellfishrc` file on the server. To do this, go to the app options in iOS, select `Shell Integration`, press `Install`, and choose the server where you want to include it.

The file will be added to the home folder of your user on the server. If it is different from root, modify the path in the third line of the script `source /root/.shellfishrc` to the correct one `source /your_user/.shellfishrc`.

## Usage

All the widgets that will be added to this repository will be used in the same way. If there is any difference, it will be indicated in its section.

1. Download the .sh file to your server, for example (you can change the path `/opt/shellfish_widgets` to any other:
   ```bash
   mkdir /opt/shellfish_widgets
   cd /opt/shellfish_widgets
   wget https://github.com/jmrplens/ShellFish-Widgets/raw/main/small_widget_A.sh
   ```
2. Enable its execution:
   ```
   chmod +x /opt/shellfish_widgets/small_widget_A.sh
   ```
3. Run it:
   ```
   /opt/shellfish_widgets/small_widget_A.sh --server-name Example
   ```
   With this, you will have already sent the information to the widget you set on your iOS. If you want, you can configure some details:
   - **Server name**: This is the name that will appear on the widget `--server-name Example`.
   - **Disk**: If you want to send the used space of a disk other than the main one `--disk /volumeX`.
   - **CPU temperature**: If you want to use another sensor or manually specify the sensor because it is not recognized `--cpu_sensor Tctl`.
   - **Target**: To send the information to a specific widget, indicate the widget's reference `--target widget1`.

4. (Optional) Add it to the crontab (in this example, it runs every 10 minutes) to have updated information periodically:
   ```
   { crontab -l; echo "*/10 * * * * /opt/shellfish_widgets/small_widget_A.sh"; } | crontab -
   ```
   or `crontab -e` and add a new line with `*/10 * * * * /opt/shellfish_widgets/small_widget_A.sh`

### Small Widgets

#### Type A

By running `./your_path/small_widget_A.sh --server-name Example`, the widget will look like this:

<img src=".github/small_widget_A.png" width="150">
