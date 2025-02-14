"""Script that generates a list of users that should be assigned O365 licenses.

https://github.com/Philip-Greyson/D118-O365-Licensing

Needs oracledb: pip install oracledb --upgrade
"""

# importing module
import oracledb # used to connect to PowerSchool database
import os # needed to get environement variables
from datetime import datetime as dt  # just used to log start and end time so we know how long execution took

DB_UN = os.environ.get('POWERSCHOOL_READ_USER') # username for read-only database user
DB_PW = os.environ.get('POWERSCHOOL_DB_PASSWORD') # the password for the database account
DB_CS = os.environ.get('POWERSCHOOL_PROD_DB') # the IP address, port, and database name to connect to

print(f"DB Username: {DB_UN} |DBPassword: {DB_PW} |DBServer: {DB_CS}") # debug so we can see where oracle is trying to connect to/with

BAD_NAMES = ['use', 'training1','trianing2','trianing3','trianing4','planning','admin','administrator','nurse','user','use ','payroll','human','benefits','test']  # list of names (in all lowercase) that will be ignored
SCHOOLS_EVERY_USER = [131, 133, 134, 135]  # schools where every user who is not an ignored name will get a license regardless of their job classification
CLASSIFICATIONS_FOR_LICENSES = [700, 703, 704, 800, 801, 802, 193, 293, 393, 410, 510, 610, 190, 191, 290, 291, 390, 391, 180, 280, 380, 192, 292, 392, 480, 580, 680, 395, 396, 911, 383, 230, 330, 281, 381]  # list of classification codes that will get licenses (unless they have an ignored name)


if __name__ == '__main__': # main file execution
    with open('O365_python_log.txt', 'w') as log:
        with open('user_list.csv', 'w') as output:
            startTime = dt.now()
            startTime = startTime.strftime('%H:%M:%S')
            print(f'INFO: Execution started at {startTime}')
            print(f'INFO: Execution started at {startTime}', file=log)
            with oracledb.connect(user=DB_UN, password=DB_PW, dsn=DB_CS) as con: # create the connecton to the database
                print(f'INFO: Connection established to PS database on version: {con.version}')
                print(f'INFO: Connection established to PS database on version: {con.version}', file=log)
                with con.cursor() as cur:  # start an entry cursor
                    # Start by getting a list of schools from the schools table view to get the school names, numbers, etc for use
                    cur.execute('SELECT name, school_number FROM schools')
                    schools = cur.fetchall()
                    for school in schools:
                        # store results in variables mostly just for readability
                        schoolName = school[0].title()  # convert to title case since some are all caps
                        schoolNum = school[1]
                        # now search for active users with an email (to filter some dummy accounts) in each building
                        cur.execute('SELECT u.first_name, u.last_name, u.email_addr, hr.sfe_position, u.dcid FROM users u LEFT JOIN u_humanresources hr ON u.dcid = hr.usersdcid WHERE u.homeschoolid = :school AND email_addr IS NOT NULL', school=schoolNum)
                        users = cur.fetchall()
                        for user in users:
                            firstName = user[0] if user[0] else ''
                            lastName = user[1] if user[1] else ''
                            email = user[2]
                            classification = int(user[3]) if user[3] else None
                            uDCID = int(user[4])
                            # check their schoolstaff entries to make sure they are active in their homeschool
                            cur.execute('SELECT schoolid, status, staffstatus FROM schoolstaff WHERE users_dcid = :dcid AND status = 1 AND schoolid = :school', dcid=uDCID, school=schoolNum)
                            schoolStaff = cur.fetchall()
                            if schoolStaff:  # if we found a result in schoolstaff, that means they are active in their homeschool
                                print(f'DBUG: Found active user {email}, {schoolStaff}')  # debug
                                if (schoolNum in SCHOOLS_EVERY_USER) or (classification in CLASSIFICATIONS_FOR_LICENSES):  # if they are in a building where we give all users licenses, or their classification matches
                                    print(user)  # debug
                                    if firstName.lower() in BAD_NAMES or lastName.lower() in BAD_NAMES:  # if their first or last name matches a bad name after being converted to lowercase match a bad name, ignore them and throw a warning
                                        print(f'WARN: Found user {firstName} {lastName} - {email} with good classification or building that matches the bad name list and will be skipped')
                                        print(f'WARN: Found user {firstName} {lastName} - {email} that good classification or building that matches the bad name list and will be skipped', file=log)
                                    else:
                                        print(f'DBUG: User {firstName} {lastName} - {email} with classification {classification} should be assigned a license')
                                        print(f'DBUG: User {firstName} {lastName} - {email} with classification {classification} should be assigned a license', file=log)
                                        print(email, file=output)
                            else:
                                print(f'DBUG: Found inactive user {email}')
            endTime = dt.now()
            endTime = endTime.strftime('%H:%M:%S')
            print(f'INFO: Execution started at {endTime}')
            print(f'INFO: Execution started at {endTime}', file=log)

