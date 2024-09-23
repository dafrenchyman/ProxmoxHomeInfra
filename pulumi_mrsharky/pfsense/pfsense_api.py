import json
from typing import List

import requests


class PfsenseApi:
    def __init__(
        self, username: str, password: str, url: str, verify_cert: bool = True
    ):
        self.username = username
        self.password = password
        self.url = url
        self.verify_cert = verify_cert
        self.json_headers = {"Content-Type": "application/json"}

    def _handle_error(self, response):
        raise Exception(
            f"Received the following error {response.status_code}: {response}"
        )

    def create_user_group(
        self,
        group_name: str,
        scope: str,
        description: str,
        members: List[str] = None,
        privileges: List[str] = None,
    ):

        end_point = f"https://{self.url}/api/v2/user/group"
        data = {
            "name": group_name,
            "scope": scope,
        }

        if description is not None:
            data["description"] = description
        if members is not None:
            # Make sure the members all exist
            for member in members:
                _ = self.get_user_by_username(username=member)
            data["member"] = members
        if privileges is not None:
            data["priv"] = privileges

        response = requests.post(
            end_point,
            auth=(self.username, self.password),
            data=json.dumps(data),
            headers=self.json_headers,
            verify=self.verify_cert,
        )

        if response.status_code != 200:
            self._handle_error(response)

        return

    def delete_user_group(
        self,
        group_name: str,
    ):
        end_point = f"https://{self.url}/api/v2/user/group"

        curr_data = self.get_group_by_group_name(group_name)
        response = requests.delete(
            end_point,
            auth=(self.username, self.password),
            params={
                "id": curr_data.get("id"),
            },
            verify=self.verify_cert,
        )

        if response.status_code != 200:
            self._handle_error(response)

    def get_user_groups(self):
        end_point = f"https://{self.url}/api/v2/user/groups"

        # Send a GET request to the specified URL
        response = requests.get(
            url=end_point, auth=(self.username, self.password), verify=self.verify_cert
        )

        if response.status_code != 200:
            self._handle_error(response)

        # Parse the JSON content of the response
        data = response.json().get("data")

        return data

    def add_user_to_group(self, username: str, group_name: str):
        _ = self.get_user_by_username(username=username)
        group = self.get_group_by_group_name(group_name=group_name)
        group_members: List[str] = group.get("member")

        group_members.append(username)
        self.update_user_group(
            group_name=group_name,
            members=group_members,
            scope=group.get("scope"),
        )

        return

    def update_user_group(
        self,
        group_name: str,
        scope: str = None,
        description: str = None,
        members: List[str] = None,
        privileges: List[str] = None,
    ):
        end_point = f"https://{self.url}/api/v2/user/group"

        curr_data = self.get_group_by_group_name(group_name=group_name)
        data = {
            "id": curr_data.get("id"),
            "name": group_name,
        }
        if scope is not None:
            data["scope"] = scope
        if description is not None:
            data["description"] = description
        if members is not None:
            data["member"] = members
        if privileges is not None:
            data["priv"] = privileges

        response = requests.patch(
            end_point,
            auth=(self.username, self.password),
            data=json.dumps(data),
            headers=self.json_headers,
            verify=self.verify_cert,
        )

        if response.status_code != 200:
            self._handle_error(response)

        return

    def get_users(self):
        end_point = f"https://{self.url}/api/v2/users"

        # Send a GET request to the specified URL
        response = requests.get(
            url=end_point, auth=(self.username, self.password), verify=self.verify_cert
        )

        if response.status_code != 200:
            self._handle_error(response)

        # Parse the JSON content of the response
        data = response.json().get("data")

        return data

    def get_group_by_group_name(self, group_name: str):
        users = self.get_user_groups()
        for user in users:
            if user.get("name") == group_name:
                return user

        # Didn't find the username
        raise Exception(f"Groupname '{group_name}' not found")

    def get_user_by_username(self, username: str):
        users = self.get_users()
        for user in users:
            if user.get("name") == username:
                return user

        # Didn't find the username
        raise Exception(f"Username '{username}' not found")

    def get_user(self):
        return

    def create_user(
        self,
        username: str,
        password: str,
        privileges: List[str],
        disable: bool,
        description: str,
        expires: str = None,
        certs: List[str] = None,
        authorized_keys: str = None,
        ipsecpsk: str = None,
    ):
        end_point = f"https://{self.url}/api/v2/user"

        data = {
            "name": username,
            "password": password,
            "priv": privileges,
            "disabled": disable,
            "descr": description,
            "expires": expires,
            "cert": certs,
            "authorizedkeys": authorized_keys,
            "ipsecpsk": ipsecpsk,
        }

        response = requests.post(
            end_point,
            auth=(self.username, self.password),
            data=json.dumps(data),
            headers=self.json_headers,
            verify=self.verify_cert,
        )
        if response.status_code != 200:
            self._handle_error(response)

        return

    def update_user(
        self,
        username: str,
        password: str = None,
        privileges: List[str] = None,
        disable: bool = None,
        description: str = None,
        expires: str = None,
        certs: List[str] = None,
        authorized_keys: str = None,
        ipsecpsk: str = None,
    ):
        headers = {"Content-Type": "application/json"}
        end_point = f"https://{self.url}/api/v2/user"

        curr_data = self.get_user_by_username(username)

        data = {
            "id": curr_data.get("id"),
            "name": username,
        }
        if password is not None:
            data["password"] = password
        if privileges is not None:
            data["priv"] = privileges
        if disable is not None:
            data["disabled"] = disable
        if description is not None:
            data["descr"] = description
        if expires is not None:
            data["expires"] = expires
        if certs is not None:
            data["cert"] = certs
        if authorized_keys is not None:
            data["authorizedkeys"] = authorized_keys
        if ipsecpsk is not None:
            data["ipsecpsk"] = ipsecpsk

        response = requests.patch(
            end_point,
            auth=(self.username, self.password),
            data=json.dumps(data),
            headers=headers,
            verify=self.verify_cert,
        )

        if response.status_code != 200:
            self._handle_error(response)

        return

    def delete_user(self, username: str) -> None:
        end_point = f"https://{self.url}/api/v2/user"

        curr_data = self.get_user_by_username(username)
        response = requests.delete(
            end_point,
            auth=(self.username, self.password),
            params={
                "id": curr_data.get("id"),
            },
            verify=self.verify_cert,
        )

        if response.status_code != 200:
            self._handle_error(response)

        return
