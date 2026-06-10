import 'dart:convert';

void main() {
  String text = r'''{
  "IsLayoutEditMode" : false,
  "ShowHamburger" : true,
  "IsLandingZone" : true,
  "IsReportExecution" : false,
  "GlobalProperties" : {
    "IsRtl" : false,
    "validationMessages" : {
      "TooManyItemsError" : "Maximum {itemLimit} files are allowed to upload at once.",
      "PDFFilesError" : "Multiple pdf files are not allowed for upload.",
      "EmptyError" : "Selected file has no data. Please select a valid file.",
      "ERR_REQUIRED" : "##CAPTION## is required",
      "LBL_POST_COMMNETS" : "Please post your comments here",
      "ERR_INVALIDECIMAL" : "Invalid decimal value. Only ##DECIMALPLACES## decimal places allowed.",
      "ERR_OBJECTBANK_MANDATORY" : "Please fill the mandatory fields to proceed further",
      "ERR_INVALID_DAYS" : "Days can not be greater than ##DAYS##",
      "ERR_INVALID_HOURS" : "Hours can not be greater than ##HOURS##",
      "ERR_INVALID_MINS" : "Mins can not be greater than ##MINS##",
      "ERR_INVALID_VALUE_FIELD_0" : "Invalid value of field ##CAPTION##.",
      "MSG_NUMERIC_VALUE" : "Please enter a Numeric Value.",
      "MSG_NUMBER_MIN_MAX" : "Please enter a value between ##MIN## to ##MAX##.",
      "MSG_CHAR_MIN_MAX" : "Please enter a value with character between ##MIN## to ##MAX##.",
      "MSG_RECORD_RETAIN" : "Do you want to retain this record?",
      "MSG_RECORD_DELETE" : "Do you want to delete this record?",
      "MSG_DELETE" : "Do you want to delete?",
      "ERR_NO_RECORD_FOUND" : "No Record Found",
      "NO_DATA_DESC" : "There is no available data to show, please choose another option and try again.",
      "CARD_NOT_CONFIGURED" : "Card Not Configured.",
      "LBL_DATE_COMPARE_MESSAGE" : "Scheduled start date should be earlier than end date.",
      "ERR_SCHEDULEDATE_CURRENT_DATE" : "Scheduled start time should be earlier than the end time.",
      "ERR_DATE_PAST" : "Date cannot be in the past",
      "ERR_TIME_PAST" : "Time cannot be in the past"
    },
    "lang" : {
      "LBL_CALCULATE" : "Calculate",
      "LBL_CANCEL" : "Cancel",
      "NO_FIELD_FOUND" : "No field found",
      "NO_DATA_FOUND" : "No data exists.",
      "LBL_RELATED_LINKS" : "Related Links",
      "LBL_UNKNOWN_ERROR" : "Unknown error.",
      "LBL_WARNING" : "Warning",
      "LBL_CONFIRMATION" : "Confirmation",
      "LBL_VALIDATION_SUMMARY" : "Validation Summary",
      "BTN_OK" : "Ok",
      "SELECT_COLOR" : "Please select color",
      "LBL_MENUITEM_SELECT_PROCESS" : "Click on menu items to select processes.",
      "LBL_SELECTED_ITEMS" : "Selected items",
      "LBL_TOTAL_SELECTED_RECORDS" : "Total selected records",
      "LBL_UPLOAD_PROFILE_IMAGE" : "Upload Profile Image",
      "LBL_GRID_UPDATE" : "Update Grid Fields",
      "LBL_PROFILE" : "Profile",
      "NO_FIELD_UPDATED" : "You have not changed any field. Do you still want to proceed?",
      "NO_SEARCH_CRITERIA" : "Please specify the valid search criteria.",
      "BTN_APPLY" : "Apply",
      "LBL_BTN_FILTER" : "Filter",
      "BTN_CLEAR" : "Clear",
      "LBL_DEDUPE_LISTING" : "Duplicate Record Listing",
      "LBL_PER_PAGE" : " per page",
      "LBL_SHOW" : "Show",
      "LBL_EXECUTE" : "Execute",
      "BTN_QUICKSEARCHBYSTRATEGY" : "Search",
      "LBL_SEARCH_BY" : "Search By",
      "LBL_STAGE_MESSAGE" : "This stage does not require any additional information",
      "LBL_FILTERS" : "Filters",
      "LBL_GROUPBY_COLUMN" : "Drag a column header here to group by that column",
      "BTN_SELECT" : "Select",
      "LBL_SELECT_ALL" : "Select All",
      "LBL_COPY" : "Copy",
      "LBL_GO_TO" : "Go to",
      "LBL_MONTH" : "Month",
      "LBL_DAY" : "Day",
      "LBL_WEEK" : "Week",
      "LBL_TODAY" : "Today",
      "LBL_SEVENDAYS" : "7 Days",
      "LBL_SCOPE" : "Scope",
      "LBL_SELECT_CALEANDER" : "Select Calendar",
      "LBL_SELECT" : "Select",
      "LBL_TYPE_TO_SEARCH_USER" : "Type To Search User",
      "ERR_FG_CROPFILESIZE" : "Cropped Image is greater than Cropped Size. Cropped Size is of",
      "LBL_GRAPHFILTER" : "Graph Filter",
      "LBL_DRAG_OPTION" : "You can drag the options in the right box up and down through mouse.",
      "LBL_NO_SECTION_FOUND" : "No Sections Found",
      "LBL_SEARCH" : "Search",
      "LBL_SUCCESS" : "Success",
      "LBL_NO_RECORD_FOUND" : "No Record Found",
      "LINK_MORE" : "More",
      "LINK_MORE_ACTIONS" : "More",
      "LINK_CLICK_FETCH" : "Fetch",
      "LBL_DMSATTACHMENT" : "DMS Attachment",
      "LBL_FILEINPUT" : "File Input",
      "LBL_WEBScan" : "Web Scan",
      "LBL_NOCOACHTEXT" : "No Coach Text !",
      "BTN_ADD" : "Add",
      "LBL_NEXTPOSSIBLESTATES" : "Next Possible States",
      "LBL_NOTE" : "Note",
      "LBL_RSSCATEGORY" : "Category:",
      "LBL_SwitchView" : "Switch View",
      "LNK_ShowMore" : "Show More",
      "LBL_SELECT_DASHBOARD" : "Select Dashboard",
      "Lnk_Like" : "Like",
      "Lnk_UnLike" : "UnLike",
      "LBL_COMMENT" : "Comments",
      "LBL_UPLOADFILES" : "Upload Files",
      "LBL_FOLLOW" : "Follow",
      "LBL_UNFOLLOW" : "UnFollow",
      "LBL_ADD_PRODUCTS" : "Add Products To Price Book",
      "LBL_RELOAD" : "Reload",
      "LNK_ADDNEW" : "Add New",
      "LBL_ADD_RECORDITEM" : "Add Record Item",
      "BTN_New" : "New",
      "LBL_REFRESH" : "Refresh",
      "LBL_FILTERBY" : "Filter By",
      "Private" : "Private",
      "LBL_QUICK_ACTION_HIDE" : "QuickAction",
      "LBL_PULSE" : "Pulse",
      "BTN_ACTION" : "Action",
      "BTN_COLUMN_OPTION" : "Column Option",
      "LBL_VIEWS" : "Views",
      "LBL_SORT_BY" : "Sort By",
      "LBL_SET_ORDER" : "Set Order",
      "LBL_KANBAN" : "kanban",
      "LBL_TABLE_VIEW" : "Table View",
      "LBL_SPLIT_VIEW" : "Split View",
      "LBL_CALENDAR_VIEW" : "Calendar View",
      "LBL_LIST_VIEW" : "List View",
      "LBL_ALL" : "All",
      "LBL_TAGGED" : "Tagged",
      "LBL_PRODUCT_SALES_TRENDS" : "Product Sales Trends",
      "LBL_GRAND" : "Grand",
      "LINK_VIEWBOARD" : "Boards",
      "PLANNER_CARD_DESC" : "Here All your Planned life events, you will find information for each Life event as well you can planned new one",
      "LBL_COLUMN_REORDER" : "Column Reorder",
      "BTN_RESTORE_DEFAULT" : "Restore Default",
      "BTN_APPLY_CLOSE" : "Apply & Close",
      "LBL_FEED_NAME" : "Feed Name",
      "CATEGORY" : "Category",
      "AUDIO_RECORD_INSTRUCTION" : "Please place the device centrally to capture better audio.",
      "MESSAGE_MIN" : "Please select at least ##MIN##",
      "Choose_Your_view" : "Choose your view",
      "LBL_SWITCH_TO_CALENDAR" : "Switch to Calendar",
      "LBL_LISTING_VIEW" : "Listing View",
      "LBL_MY_CALENDARS" : "My calendars",
      "LBL_SWITCH_TO_LISTING" : "Switch to Listing",
      "ERROR_CHATMODULE_ALERT" : "Please change agent status from (available or busy) to offline",
      "LBL_HI" : "Hi",
      "LBL_HOW_CAN_WE_HELP" : "how can we help",
      "LBL_TYPE_YOUR_CONTENT" : "Type Your Content...",
      "BTN_USERCHAT" : "Chat",
      "LBL_SUBMIT_REVIEW" : "Submit Review",
      "LBL_DRAG_AND_DROP" : "Drag & drop or",
      "LBL_CHOOSE_FILES" : "choose files",
      "LBL_WE_SUPPORT" : "We support",
      "LBL_TYPES_FILES" : "types files",
      "LBL_TYPES_Remark" : "Remark",
      "LBL_AVAILED" : "Availed",
      "LBL_NOT_AVAILED" : "Not Availed",
      "LBL_OF_SIZE" : "of size",
      "LBL_ONE_TIME_SETUP_LANG_KEY" : "One Time SetUp",
      "LBL_ADD_DETAIL_LANG_KEY" : "Add Details",
      "LBL_ADD_NEW_ADDRESS_LANG_KEY" : "Add New Address",
      "LBL_SAVED_ADDRESS_LANG_KEY" : "Saved Addresses",
      "LBL_ADDRESS_DETAILS_LANG_KEY" : "Address Details",
      "LBL_ADDRESS_TAG_LANG_KEY" : "Tag address as",
      "LBL_ADDRESS_FLAT_LANG_KEY" : "House/Flat/Floor No.",
      "LBL_ADDRESS_APARTMENT_LANG_KEY" : "Apartment/Road/Area",
      "LBL_ADD_ADDRESS_MSG_LANG_KEY" : "Add your first address to set up your trips and plan your routes seamlessly.",
      "LBL_ADD_A_NEW_ADDRESS_LANG_KEY" : "Add a new address",
      "LBL_MANAGE_ADDRESS_LANG_KEY" : "Manage Addresses",
      "LBL_HOME_ADDRESS_TAG_LANG_KEY" : "Home",
      "LBL_WORK_ADDRESS_TAG_LANG_KEY" : "Work",
      "LBL_OTHER_ADDRESS_TAG_LANG_KEY" : "Other",
      "LBL_SetUp_LANG_KEY" : "Setup",
      "LBL_Duration_Between_LANG_KEY" : "Make sure the duration between start and end time is at least ##time_diff## hours for setting up your trip.",
      "LBL_Serach_Any_LANG_KEY" : "Search for any area, name, location...",
      "LBL_StartEndTime_LANG_KEY" : "Please ensure both start and end times are set before proceeding",
      "LBL_StartEndAddress_LANG_KEY" : "Please ensure both start and end addresses are set before proceeding.",
      "LBL_Distance_Greater_LANG_KEY" : "Distance is greater than ##distance_diff## km. Proceeding with the trip setup.",
      "LBL_Plan_Detail_LANG_KEY" : "Add Plan Details",
      "LBL_Object_Selection_LANG_KEY" : "Select Object(s)",
      "LBL_Plan_Days_LANG_KEY" : "Plan Your Days",
      "LBL_Not_At_Meeting_Location" : "You are not at the meeting location You can't check in",
      "LBL_Date_Between_LANG_KEY" : "Select a date range to plan your schedule.",
      "LBL_End_Date_Validation_LANG_KEY" : "End date cannot be before start date.",
      "LBL_Holiday_LANG_KEY" : "Holiday",
      "LBL_Working_LANG_KEY" : "Working",
      "LBL_Distance_LANG_KEY" : "Distance",
      "LBL_Date_Fields_LANG_KEY" : "Please Select Date and Assigned Fields",
      "ERR_No_Records_Found_In_Date_Range" : "No records found in date range",
      "LBL_Add_Assigned_Records_LANG_KEY" : "No records found in date range",
      "LBL_Please_select_Atleast_One_Object_LANG_KEY" : "Please select at least one object",
      "LBL_Add_LANG_KEY" : "Add",
      "LBL_Choose_Distance_LANG_KEY" : "Choose Distance",
      "ERR_Date_Not_Select_Less_Than_MinDays" : "Please Select Date and Assigned Fields",
      "ERR_Date_Not_Select_More_Than_MaxDays" : "Please Select Date and Assigned Fields",
      "MSG_Unselect_Object_Deletes_Data" : "Unselecting ##ObjectName## will remove all the records added for the selected date range. Are you sure you want to continue?",
      "MSG_Tab_Switch_Discards_Data" : "Switching tabs will discard your selected data. Do you want to continue?",
      "LBL_Holiday_Removal_Confirmation" : "Marking this day as a holiday will remove all added items. Do you want to continue?",
      "LBL_Select_At_Least_One_Item" : "Please select at least one item against any day",
      "LBL_Add_Max_Count_Address" : "Please select at least one item against any day",
      "No_Supported_Maps_Mobile_Device" : "No supported maps application found on this device",
      "LBL_Please_keep_in_mind" : "Please keep in mind",
      "LBL_Get_accurate_trip_details" : "Keep your GPS on and battery optimization off through the trip to get accurate trip details.",
      "LBL_Okay" : "Okay",
      "LBL_SCHEDULED_DAILY_AT" : "Scheduled to run at _ from _",
      "LBL_SCHEDULED_EVERY_DAY" : "Scheduled to run from _ , starting _",
      "LBL_SCHEDULED_EVERY_DAY_WEEKLY" : "Scheduled to run _ at _, starting _",
      "LBL_SCHEDULED_MONTHLY_STARTING" : "Scheduled to run on day _, every _ at _, starting _",
      "LBL_SCHEDULED_MONTHLY_STARTING_WEEKLY" : "Scheduled to run _ at _, every _, starting _",
      "LBL_SCHEDULED_ONETIME" : "Scheduled to run on _",
      "LBL_SUMMARY" : "Summary",
      "LBL_ON" : "On",
      "LBL_EVERY" : "Every",
      "LBL_OF_THE" : "of the",
      "LBL_MONTHS" : "Months",
      "LBL_Finish" : "Finish",
      "LBL_STEP" : "Step",
      "GHD_WIDGETLIST" : "Widget Listing",
      "LBL_DEFENITION" : "Definition",
      "LBL_ENTER_KEY_INFO" : "Enter key information",
      "LBL_VALIDATE_DESCRIPTION" : "Validate {0} by following the simple steps of this wizard.",
      "LBL_WIDGET_LISTING_ALERT" : "Please select one item from listing
  "NativeAuditLog" : {
    "TimeStamp" : "06/10/2026 11:53:15 AM",
    "AuditScreen" : "HomePage",
    "Attributes" : {
      "AccessType" : "Summary"
    },
    "EmployeeCode" : "",
    "EmployeeRole" : "Mahib NON admin",
    "LoginId" : "Mahib"
  }
}''';

  // 1. Strip comments
  text = text.replaceAll(RegExp(r'\/\*[\s\S]*?\*\/'), '');
  text = text.split('\n').map((line) {
    int idx = line.indexOf('//');
    if (idx != -1) {
      if (idx > 0 && line[idx - 1] == ':') {
        return line;
      }
      return line.substring(0, idx);
    }
    return line;
  }).join('\n');

  // 1b. Fix unclosed strings and raw newlines inside strings
  List<String> lines = text.split('\n');
  bool changed = true;
  while (changed) {
    changed = false;
    String? currentQuoteChar;
    for (int i = 0; i < lines.length; i++) {
      String line = lines[i];
      bool escaped = false;
      for (int j = 0; j < line.length; j++) {
        if (line[j] == '\\') {
          escaped = !escaped;
        } else if (line[j] == '"') {
          if (!escaped) {
            if (currentQuoteChar == null) {
              currentQuoteChar = '"';
            } else if (currentQuoteChar == '"') {
              currentQuoteChar = null;
            }
          }
          escaped = false;
        } else if (line[j] == '\'') {
          if (!escaped) {
            if (currentQuoteChar == null) {
              currentQuoteChar = '\'';
            } else if (currentQuoteChar == '\'') {
              currentQuoteChar = null;
            }
          }
          escaped = false;
        } else {
          escaped = false;
        }
      }

      if (currentQuoteChar != null) {
        bool isNextKeyValue = false;
        int nextNonEmptyIdx = -1;
        for (int k = i + 1; k < lines.length; k++) {
          String nextLine = lines[k].trim();
          if (nextLine.isNotEmpty) {
            nextNonEmptyIdx = k;
            if (RegExp(r'^((?:"|\x27)?[a-zA-Z0-9_-]+(?:"|\x27)?\s*:)').hasMatch(nextLine)) {
              isNextKeyValue = true;
            }
            break;
          }
        }

        if (isNextKeyValue || nextNonEmptyIdx == -1) {
          String trimmedLine = line.trimRight();
          if (trimmedLine.endsWith(',')) {
            trimmedLine = trimmedLine.substring(0, trimmedLine.length - 1).trimRight();
            lines[i] = trimmedLine + currentQuoteChar + ',';
          } else {
            lines[i] = trimmedLine + currentQuoteChar;
          }
          currentQuoteChar = null;
          changed = true;
          break;
        } else {
          if (i + 1 < lines.length) {
            lines[i] = line + '\\n' + lines[i + 1];
            lines.removeAt(i + 1);
            changed = true;
            break;
          }
        }
      }
    }
  }
  text = lines.join('\n');

  // 2. Replace single quotes with double quotes
  StringBuffer fixedQuotes = StringBuffer();
  bool inDoubleQuote = false;
  bool inSingleQuote = false;
  for (int i = 0; i < text.length; i++) {
    String c = text[i];
    if (c == '"' && !inSingleQuote) {
      if (i > 0 && text[i - 1] == '\\') {
        fixedQuotes.write(c);
      } else {
        inDoubleQuote = !inDoubleQuote;
        fixedQuotes.write(c);
      }
    } else if (c == '\'' && !inDoubleQuote) {
      if (i > 0 && text[i - 1] == '\\') {
        fixedQuotes.write(c);
      } else {
        inSingleQuote = !inSingleQuote;
        fixedQuotes.write('"');
      }
    } else {
      fixedQuotes.write(c);
    }
  }
  text = fixedQuotes.toString();

  // 3. Fix unquoted keys
  text = text.replaceAllMapped(
    RegExp(r'([{,]\s*)([a-zA-Z_][a-zA-Z0-9_-]*)\s*:'),
    (match) => '${match.group(1)}"${match.group(2)}":',
  );

  // 4. Remove trailing commas before closing braces/brackets
  text = text.replaceAllMapped(
    RegExp(r',\s*([\]}])'),
    (match) => match.group(1)!,
  );

  // 5. Add missing commas
  text = text.replaceAllMapped(
    RegExp(r'("|\d|true|false|null)\s+("([a-zA-Z0-9_-]+)"\s*:)'),
    (match) => '${match.group(1)}, ${match.group(2)}',
  );

  // 6. Balance brackets/braces
  int openBraces = 0;
  int closeBraces = 0;
  int openBrackets = 0;
  int closeBrackets = 0;
  bool inString = false;

  for (int i = 0; i < text.length; i++) {
    String c = text[i];
    if (c == '"' && (i == 0 || text[i - 1] != '\\')) {
      inString = !inString;
    }
    if (!inString) {
      if (c == '{') openBraces++;
      if (c == '}') closeBraces++;
      if (c == '[') openBrackets++;
      if (c == ']') closeBrackets++;
    }
  }

  print("Open Braces: $openBraces, Close Braces: $closeBraces");
  print("Open Brackets: $openBrackets, Close Brackets: $closeBrackets");

  if (openBrackets > closeBrackets) {
    text = text + (']' * (openBrackets - closeBrackets));
  }
  if (openBraces > closeBraces) {
    text = text + ('}' * (openBraces - closeBraces));
  }

  print("--- RESULT ---");
  print(text);

  try {
    json.decode(text);
    print("SUCCESSFULLY PARSED!");
  } on FormatException catch (e) {
    print("FAILED TO PARSE: ${e.message} at line ${e.offset}");
  }
}
