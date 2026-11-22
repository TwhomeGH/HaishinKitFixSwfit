# OpenSSL

這個目錄追蹤兩個 XCFramework 內含的加密依賴，目前不是新的套件引用。

libdatachannel 腳本指定封裝專案 tag 3.3.3001；libsrt 腳本沒有鎖定 OpenSSL。
兩者的 actualBinaryVersion 仍為 null，不能把封裝 tag 或 ZIP checksum 當成內含 OpenSSL 版本證明。

優先取得發布來源／建置紀錄與產物版本證據，再決定是否採用共用 OpenSSL 套件。
同時連結時需檢查靜態符號與版本衝突，尚未重現衝突，不預設升級方案已決定。
